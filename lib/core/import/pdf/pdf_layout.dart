import 'dart:typed_data';

/// Plain, isolate-friendly description of what a PDF page contains. The
/// converter fills it from PDFium; the heuristics only ever see these types,
/// so they can be unit-tested without a PDF engine.
///
/// Coordinates follow PDF conventions: points, origin at the bottom left, so
/// [PdfTextLine.top] is greater than [PdfTextLine.bottom].
class PdfTextLine {
  const PdfTextLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.size,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// Approximate font size in points.
  final double size;

  double get width => right - left;
  double get height => top - bottom;

  PdfTextLine copyWith({String? text}) => PdfTextLine(
    text: text ?? this.text,
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    size: size,
  );

  @override
  String toString() =>
      'PdfTextLine("$text", x ${left.round()}-${right.round()}, '
      'y ${bottom.round()}-${top.round()}, size ${size.toStringAsFixed(1)})';
}

class PdfPageLayout {
  const PdfPageLayout({
    required this.pageNumber,
    required this.width,
    required this.height,
    required this.lines,
  });

  /// 1-based page number.
  final int pageNumber;
  final double width;
  final double height;

  /// Lines in reading order.
  final List<PdfTextLine> lines;

  int get characterCount =>
      lines.fold(0, (sum, line) => sum + line.text.trim().length);
}

/// A PDF bookmark flattened to a list.
class PdfOutlineEntry {
  const PdfOutlineEntry({
    required this.title,
    required this.pageNumber,
    required this.level,
  });

  final String title;

  /// 1-based page number, or null when the bookmark has no destination.
  final int? pageNumber;

  /// 0 for top-level bookmarks.
  final int level;
}

/// Raw PDFium text for one page: one character per rect, with line breaks
/// as `\r\n` or `\n`. [rects] holds `left, top, right, bottom` for every
/// UTF-16 code unit of [text].
class PdfRawPageText {
  const PdfRawPageText({
    required this.pageNumber,
    required this.width,
    required this.height,
    required this.text,
    required this.rects,
  });

  final int pageNumber;
  final double width;
  final double height;
  final String text;
  final Float64List rects;
}
