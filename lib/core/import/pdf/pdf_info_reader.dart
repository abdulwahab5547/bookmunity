import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';

class PdfInfo {
  const PdfInfo({this.title, this.author, this.language});

  final String? title;
  final String? author;
  final String? language;
}

/// Reads the title and author from a PDF's document information dictionary
/// or XMP packet. PDFium (through pdfrx) does not expose them, so this scans
/// the file directly. Only the first and last few megabytes are scanned,
/// which is where writers put these objects, so huge scans stay cheap.
class PdfInfoReader {
  const PdfInfoReader();

  static const _window = 3 * 1024 * 1024;

  PdfInfo read(List<int> bytes, {String? filename}) {
    final chunks = <String>[];
    if (bytes.length <= _window * 2) {
      chunks.add(latin1.decode(bytes, allowInvalid: true));
    } else {
      chunks
        ..add(latin1.decode(bytes.sublist(0, _window), allowInvalid: true))
        ..add(
          latin1.decode(
            bytes.sublist(bytes.length - _window),
            allowInvalid: true,
          ),
        );
    }

    String? title;
    String? author;
    String? language;
    for (final chunk in chunks) {
      title ??= _value(chunk, 'Title');
      author ??= _value(chunk, 'Author');
      language ??= _value(chunk, 'Lang');
      title ??= _xmp(chunk, 'title');
      author ??= _xmp(chunk, 'creator');
    }
    if (title == null || author == null) {
      // Modern writers hide the info dictionary in compressed object
      // streams.
      for (final chunk in chunks) {
        for (final text in _objectStreams(chunk)) {
          title ??= _value(text, 'Title');
          author ??= _value(text, 'Author');
          title ??= _xmp(text, 'title');
          author ??= _xmp(text, 'creator');
          if (title != null && author != null) break;
        }
      }
    }
    return PdfInfo(
      title: cleanTitle(title),
      author: cleanAuthor(author),
      language: language == null || language.length > 12 ? null : language,
    );
  }

  /// Title from the file name, e.g. `the_time-machine (1).pdf` →
  /// `The Time Machine`.
  static String titleFromFilename(String? filename) {
    var name = (filename ?? '').split(RegExp(r'[/\\]')).last;
    name = name.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
    name = name
        .replaceAll(RegExp(r'\(\d+\)$'), '')
        .replaceAll(RegExp(r'[_\-.]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.isEmpty) return 'Untitled PDF';
    if (name == name.toLowerCase() || name == name.toUpperCase()) {
      name = name
          .split(' ')
          .map(
            (word) => word.isEmpty
                ? word
                : word[0].toUpperCase() + word.substring(1).toLowerCase(),
          )
          .join(' ');
    }
    return name;
  }

  static String? cleanTitle(String? value) {
    if (value == null) return null;
    var title = value
        .replaceFirst(
          RegExp(r'^(microsoft (word|powerpoint) - )', caseSensitive: false),
          '',
        )
        .replaceFirst(
          RegExp(
            r'\.(docx?|pdf|odt|rtf|txt|indd|pages|tex|pptx?)$',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final lower = title.toLowerCase();
    if (title.length < 2 ||
        const {'untitled', 'title', 'document', 'unknown', 'none'}.contains(lower) ||
        RegExp(r'^(document|untitled|doc)\s*\d*$').hasMatch(lower) ||
        // A file name or job id rather than a title.
        (!title.contains(' ') && RegExp(r'[_\d]').hasMatch(title)) ||
        title.length > 200) {
      return null;
    }
    return title;
  }

  static String? cleanAuthor(String? value) {
    if (value == null) return null;
    final author = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    final lower = author.toLowerCase();
    if (author.length < 2 ||
        author.length > 120 ||
        const {'unknown', 'anonymous', 'author', 'admin', 'user', 'owner'}
            .contains(lower)) {
      return null;
    }
    return author;
  }

  String? _value(String text, String key) {
    final match = RegExp('/$key\\s*([(<])').firstMatch(text);
    if (match == null) return null;
    final start = match.end - 1;
    final decoded = text[start] == '('
        ? _literal(text, start)
        : _hex(text, start);
    if (decoded == null) return null;
    final value = decoded.trim();
    return value.isEmpty ? null : value;
  }

  String? _literal(String text, int start) {
    final bytes = <int>[];
    var depth = 0;
    for (var i = start; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x5C /* \ */ ) {
        if (i + 1 >= text.length) break;
        final n = text[i + 1];
        i++;
        switch (n) {
          case 'n':
            bytes.add(0x0A);
          case 'r':
            bytes.add(0x0D);
          case 't':
            bytes.add(0x09);
          case 'b':
            bytes.add(0x08);
          case 'f':
            bytes.add(0x0C);
          case '\r':
          case '\n':
            break;
          default:
            if (RegExp('[0-7]').hasMatch(n)) {
              var octal = n;
              while (octal.length < 3 &&
                  i + 1 < text.length &&
                  RegExp('[0-7]').hasMatch(text[i + 1])) {
                octal += text[++i];
              }
              bytes.add(int.parse(octal, radix: 8) & 0xFF);
            } else {
              bytes.add(n.codeUnitAt(0));
            }
        }
        continue;
      }
      if (c == 0x28 /* ( */ ) {
        depth++;
        if (depth == 1) continue;
      } else if (c == 0x29 /* ) */ ) {
        depth--;
        if (depth == 0) return _decodeTextString(bytes);
      }
      bytes.add(c & 0xFF);
      if (bytes.length > 4000) return null;
    }
    return null;
  }

  String? _hex(String text, int start) {
    final end = text.indexOf('>', start);
    if (end < 0 || end - start > 8000) return null;
    final digits = text
        .substring(start + 1, end)
        .replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^[0-9A-Fa-f]*$').hasMatch(digits)) return null;
    final padded = digits.length.isOdd ? '${digits}0' : digits;
    final bytes = <int>[
      for (var i = 0; i < padded.length; i += 2)
        int.parse(padded.substring(i, i + 2), radix: 16),
    ];
    return _decodeTextString(bytes);
  }

  /// PDF text strings are UTF-16BE with a BOM, UTF-8 with a BOM (PDF 2.0),
  /// or PDFDocEncoding (close enough to Latin-1 for titles).
  String _decodeTextString(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    return latin1.decode(bytes, allowInvalid: true);
  }

  String? _xmp(String text, String element) {
    final start = text.indexOf('<dc:$element');
    if (start < 0) return null;
    final end = text.indexOf('</dc:$element>', start);
    if (end < 0) return null;
    final inner = text.substring(start, end);
    final li = RegExp(r'<rdf:li[^>]*>([^<]*)</rdf:li>').firstMatch(inner);
    final raw = li?.group(1);
    if (raw == null) return null;
    // XMP is UTF-8; the chunk was decoded as Latin-1.
    final value = utf8.decode(latin1.encode(raw), allowMalformed: true);
    return _unescapeXml(value).trim().isEmpty ? null : _unescapeXml(value);
  }

  String _unescapeXml(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  Iterable<String> _objectStreams(String text) sync* {
    final pattern = RegExp(r'/Type\s*/(ObjStm|Metadata)');
    var found = 0;
    for (final match in pattern.allMatches(text)) {
      if (found > 40) return;
      final streamStart = text.indexOf('stream', match.end);
      if (streamStart < 0 || streamStart - match.end > 600) continue;
      var dataStart = streamStart + 'stream'.length;
      if (dataStart < text.length && text[dataStart] == '\r') dataStart++;
      if (dataStart < text.length && text[dataStart] == '\n') dataStart++;
      final end = text.indexOf('endstream', dataStart);
      if (end < 0) continue;
      final dictionary = text.substring(
        math.max(0, match.start - 400),
        streamStart,
      );
      final data = latin1.encode(text.substring(dataStart, end));
      found++;
      if (!dictionary.contains('/FlateDecode')) {
        yield latin1.decode(data, allowInvalid: true);
        continue;
      }
      try {
        final inflated = const ZLibDecoder().decodeBytes(data);
        yield latin1.decode(inflated, allowInvalid: true);
      } catch (_) {
        // Damaged or differently filtered stream; skip it.
      }
    }
  }
}
