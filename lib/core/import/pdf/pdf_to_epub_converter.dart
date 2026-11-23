import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx_engine/pdfrx_engine.dart';

import 'pdf_epub_builder.dart';
import 'pdf_info_reader.dart';
import 'pdf_layout.dart';

class PdfConversionResult {
  const PdfConversionResult({
    required this.epub,
    required this.title,
    required this.pageCount,
    required this.scanned,
  });

  final Uint8List epub;
  final String title;
  final int pageCount;

  /// The PDF had no text layer; the EPUB shows one image per page.
  final bool scanned;
}

/// Progress of a conversion, 0 to 1, with a short label for the UI.
typedef PdfConversionProgress = void Function(double fraction, String stage);

class PdfConversionCancelled implements Exception {
  const PdfConversionCancelled();

  @override
  String toString() => 'Conversion cancelled.';
}

class PdfConversionCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const PdfConversionCancelled();
  }
}

/// Converts a PDF into an EPUB 3 on the device.
///
/// PDFium work runs on pdfrx's own background isolate; line building, the
/// text heuristics, JPEG encoding and zipping run in short-lived isolates,
/// so the UI thread only coordinates.
class PdfToEpubConverter {
  PdfToEpubConverter({required this.initialize});

  /// Prepares PDFium (`pdfrxFlutterInitialize` in the app,
  /// `pdfrxInitialize` in plain Dart).
  final Future<void> Function() initialize;

  /// Width of rendered page images, in pixels.
  static const pageImageWidth = 1100;
  static const coverWidth = 600;

  /// Text PDFs keep at most this many image-only pages (plates, figures).
  static const maxInlineImages = 80;

  Future<PdfConversionResult> convert(
    Uint8List bytes, {
    String? filename,
    PdfConversionProgress? onProgress,
    PdfConversionCancelToken? cancelToken,
  }) async {
    void progress(double value, String stage) =>
        onProgress?.call(value.clamp(0.0, 1.0), stage);
    final cancel = cancelToken ?? PdfConversionCancelToken();

    if (bytes.length < 5 ||
        String.fromCharCodes(bytes.sublist(0, 5)) != '%PDF-') {
      // Some files carry junk before the header; PDFium accepts that, so
      // only reject when there is no header near the start at all.
      final head = String.fromCharCodes(bytes.take(1024));
      if (!head.contains('%PDF-')) {
        throw const FormatException('NOT A VALID PDF.');
      }
    }

    progress(0, 'Opening PDF');
    await initialize();
    final info = await _readInfo(bytes, filename);
    final fingerprint = await _fingerprint(bytes);

    final PdfDocument document;
    try {
      document = await PdfDocument.openData(
        bytes,
        sourceName: 'import:$fingerprint',
      );
    } on PdfPasswordException {
      throw const FormatException('PASSWORD PROTECTED PDF. CANNOT OPEN.');
    } on PdfException catch (error) {
      throw FormatException('THIS PDF COULD NOT BE READ. ${error.message}');
    }

    try {
      final pages = document.pages;
      if (pages.isEmpty) throw const FormatException('THIS PDF HAS NO PAGES.');
      final outline = _flattenOutline(await document.loadOutline());

      // 1. Text layer, page by page.
      final raws = <PdfRawPageText>[];
      final characters = <int>[];
      for (final page in pages) {
        cancel.throwIfCancelled();
        final raw = await page.loadText();
        final text = raw?.fullText ?? '';
        final rects = Float64List(text.length * 4);
        final charRects = raw?.charRects ?? const <PdfRect>[];
        for (var i = 0; i < text.length && i < charRects.length; i++) {
          final rect = charRects[i];
          rects[i * 4] = rect.left;
          rects[i * 4 + 1] = rect.top;
          rects[i * 4 + 2] = rect.right;
          rects[i * 4 + 3] = rect.bottom;
        }
        raws.add(
          PdfRawPageText(
            pageNumber: page.pageNumber,
            width: page.width,
            height: page.height,
            text: text,
            rects: rects,
          ),
        );
        characters.add(PdfEpubBuilder.visibleCharacters(text));
        progress(
          0.05 + 0.45 * page.pageNumber / pages.length,
          'Reading page ${page.pageNumber} of ${pages.length}',
        );
      }

      final scanned = PdfEpubBuilder.looksScanned(characters);

      // 2. Page images: every page of a scan, otherwise only pages without
      // text (illustrations), plus the cover.
      final imagePages = scanned
          ? [for (final page in pages) page.pageNumber]
          : [
              for (var i = 0; i < pages.length; i++)
                if (characters[i] < 3) pages[i].pageNumber,
            ].take(maxInlineImages).toList();
      final pageImages = <int, Uint8List>{};
      for (var i = 0; i < imagePages.length; i++) {
        cancel.throwIfCancelled();
        final number = imagePages[i];
        final jpeg = await _renderJpeg(
          pages[number - 1],
          width: pageImageWidth,
          quality: scanned ? 72 : 80,
          skipBlank: !scanned,
        );
        if (jpeg != null) pageImages[number] = jpeg;
        progress(
          0.5 + 0.35 * (i + 1) / imagePages.length,
          'Rendering page ${i + 1} of ${imagePages.length}',
        );
      }
      cancel.throwIfCancelled();
      progress(0.86, 'Making cover');
      final cover = await _renderJpeg(
        pages.first,
        width: coverWidth,
        quality: 85,
        skipBlank: false,
      );

      // 3. Heuristics and EPUB writing off the UI thread.
      cancel.throwIfCancelled();
      progress(0.9, scanned ? 'Building image book' : 'Rebuilding chapters');
      final extraction = PdfExtraction(
        pages: raws,
        outline: outline,
        info: info,
        fingerprint: fingerprint,
        filename: filename,
        coverJpeg: cover,
        pageImages: pageImages,
        scanned: scanned,
      );
      final result = await _build(extraction);
      cancel.throwIfCancelled();
      progress(1, 'Done');
      return PdfConversionResult(
        epub: result.epub,
        title: result.title,
        pageCount: pages.length,
        scanned: scanned,
      );
    } finally {
      await document.dispose();
    }
  }

  List<PdfOutlineEntry> _flattenOutline(List<PdfOutlineNode> nodes) {
    final result = <PdfOutlineEntry>[];
    void visit(List<PdfOutlineNode> list, int level) {
      for (final node in list) {
        final title = node.title.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (title.isNotEmpty) {
          result.add(
            PdfOutlineEntry(
              title: title,
              pageNumber: node.dest?.pageNumber,
              level: level,
            ),
          );
        }
        if (level < 4) visit(node.children, level + 1);
      }
    }

    visit(nodes, 0);
    return result;
  }

  Future<Uint8List?> _renderJpeg(
    PdfPage page, {
    required int width,
    required int quality,
    required bool skipBlank,
  }) async {
    if (page.width <= 0 || page.height <= 0) return null;
    final scale = width / page.width;
    final height = math.max(1, (page.height * scale).round());
    final image = await page.render(
      width: width,
      height: height,
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
      backgroundColor: 0xffffffff,
    );
    if (image == null) return null;
    final TransferableTypedData pixels;
    final int imageWidth;
    final int imageHeight;
    try {
      // The pixels may live in native memory owned by the image; copy them
      // out before disposing it.
      pixels = TransferableTypedData.fromList([image.pixels]);
      imageWidth = image.width;
      imageHeight = image.height;
    } finally {
      image.dispose();
    }
    return _encode(pixels, imageWidth, imageHeight, quality, skipBlank);
  }
}

// Isolate entry points are top-level so their closures capture nothing but
// their arguments.

Future<PdfInfo> _readInfo(Uint8List bytes, String? filename) =>
    Isolate.run(() => const PdfInfoReader().read(bytes, filename: filename));

Future<String> _fingerprint(Uint8List bytes) =>
    Isolate.run(() => PdfEpubBuilder.fingerprintOf(bytes));

Future<PdfEpubBuildResult> _build(PdfExtraction extraction) =>
    Isolate.run(() => const PdfEpubBuilder().build(extraction));

Future<Uint8List?> _encode(
  TransferableTypedData pixels,
  int width,
  int height,
  int quality,
  bool skipBlank,
) => Isolate.run(
  () => encodePageJpeg(
    pixels.materialize().asUint8List(),
    width,
    height,
    quality: quality,
    skipBlank: skipBlank,
  ),
);

/// Encodes BGRA pixels as JPEG. Returns null for a blank page when
/// [skipBlank] is set.
Uint8List? encodePageJpeg(
  Uint8List bgra,
  int width,
  int height, {
  int quality = 80,
  bool skipBlank = false,
}) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: bgra.buffer,
    bytesOffset: bgra.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.bgra,
  );
  if (skipBlank && isBlankImage(image)) return null;
  return img.encodeJpg(image, quality: quality);
}

/// True when almost every sampled pixel has the same brightness.
bool isBlankImage(img.Image image) {
  final stepX = math.max(1, image.width ~/ 60);
  final stepY = math.max(1, image.height ~/ 80);
  var samples = 0;
  var dark = 0;
  num? first;
  var different = 0;
  for (var y = 0; y < image.height; y += stepY) {
    for (var x = 0; x < image.width; x += stepX) {
      final luminance = img.getLuminance(image.getPixel(x, y));
      first ??= luminance;
      if ((luminance - first).abs() > 24) different++;
      if (luminance < 128) dark++;
      samples++;
    }
  }
  if (samples == 0) return true;
  return different / samples < 0.004 && dark / samples < 0.004;
}
