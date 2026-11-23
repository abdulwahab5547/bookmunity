import 'dart:math' as math;

import 'pdf_layout.dart';

/// Turns PDFium's raw page text (characters plus their boxes) into text
/// lines in reading order.
///
/// PDFium joins text that shares a baseline into one line even when it
/// belongs to two columns, so lines are split at wide horizontal gaps, and
/// two-column pages are re-ordered column by column.
class PdfLineBuilder {
  const PdfLineBuilder();

  static const _ligatures = {
    'ﬀ': 'ff',
    'ﬁ': 'fi',
    'ﬂ': 'fl',
    'ﬃ': 'ffi',
    'ﬄ': 'ffl',
    'ﬅ': 'st',
    'ﬆ': 'st',
  };

  // Glyphs whose box spans roughly the cap height (no descender), so their
  // height is a stable proxy for the font size.
  static final _tallGlyph = RegExp(r'[A-Z0-9bdfhklt]');
  static final _shortGlyph = RegExp(r'[acemnorsuvwxz]');

  PdfPageLayout build(PdfRawPageText raw) {
    final segments = segment(raw);
    return PdfPageLayout(
      pageNumber: raw.pageNumber,
      width: raw.width,
      height: raw.height,
      lines: orderColumns(segments, raw.width),
    );
  }

  /// Splits raw text into line segments.
  List<PdfTextLine> segment(PdfRawPageText raw) {
    final text = raw.text;
    final rects = raw.rects;
    final lines = <PdfTextLine>[];
    final buffer = StringBuffer();
    final heights = <double>[];
    final glyphs = <String>[];
    var left = double.infinity;
    var right = double.negativeInfinity;
    var top = double.negativeInfinity;
    var bottom = double.infinity;
    double? lastRight;
    double? lastBottom;
    double lastHeight = 0;

    void flush() {
      final value = _cleanText(buffer.toString());
      if (value.isNotEmpty && left.isFinite) {
        lines.add(
          PdfTextLine(
            text: value,
            left: left,
            top: top,
            right: right,
            bottom: bottom,
            size: estimateSize(glyphs, heights),
          ),
        );
      }
      buffer.clear();
      heights.clear();
      glyphs.clear();
      left = double.infinity;
      right = double.negativeInfinity;
      top = double.negativeInfinity;
      bottom = double.infinity;
      lastRight = null;
      lastBottom = null;
      lastHeight = 0;
    }

    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '\n' || char == '\r') {
        flush();
        continue;
      }
      final index = i * 4;
      if (index + 3 >= rects.length) {
        buffer.write(char);
        continue;
      }
      final l = rects[index];
      final t = rects[index + 1];
      final r = rects[index + 2];
      final b = rects[index + 3];
      final h = t - b;
      final visible = r > l && h > 0 && char.trim().isNotEmpty;
      if (visible) {
        final previousRight = lastRight;
        final previousBottom = lastBottom;
        if (previousRight != null && previousBottom != null) {
          final scale = math.max(lastHeight, h);
          final gap = l - previousRight;
          final jumpedBack = l < previousRight - scale * 4;
          final newBaseline = (b - previousBottom).abs() > scale * 0.9;
          if (gap > scale * 2.2 || jumpedBack || newBaseline) {
            flush();
          }
        }
        left = math.min(left, l);
        right = math.max(right, r);
        top = math.max(top, t);
        bottom = math.min(bottom, b);
        heights.add(h);
        glyphs.add(char);
        lastRight = r;
        lastBottom = b;
        lastHeight = h;
      }
      buffer.write(char);
    }
    flush();
    return lines;
  }

  /// Font size estimated from glyph heights: capitals, digits and ascenders
  /// are about 0.7 em tall, x-height letters about 0.5 em.
  static double estimateSize(List<String> glyphs, List<double> heights) {
    final tall = <double>[];
    final short = <double>[];
    var maxHeight = 0.0;
    for (var i = 0; i < glyphs.length; i++) {
      final height = heights[i];
      maxHeight = math.max(maxHeight, height);
      if (_tallGlyph.hasMatch(glyphs[i])) {
        tall.add(height);
      } else if (_shortGlyph.hasMatch(glyphs[i])) {
        short.add(height);
      }
    }
    if (tall.isNotEmpty) return _median(tall) / 0.7;
    if (short.isNotEmpty) return _median(short) / 0.5;
    return maxHeight / 0.75;
  }

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }

  String _cleanText(String value) {
    var result = value;
    _ligatures.forEach((from, to) => result = result.replaceAll(from, to));
    result = result
        // PDFium reports a soft hyphen at a line break as U+0002.
        .replaceAll(RegExp('[\u0002­]\$'), '-')
        .replaceAll(RegExp('[\u0000-\u0008\u000B\u000C\u000E-\u001F­�￾]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return result;
  }

  /// Re-orders lines column by column when the page has two columns.
  /// Lines that span the gutter (titles, full-width headings) stay where
  /// they are and separate column blocks above and below them.
  List<PdfTextLine> orderColumns(List<PdfTextLine> lines, double pageWidth) {
    final gutter = findGutter(lines, pageWidth);
    if (gutter == null) return lines;
    final sorted = [...lines]..sort((a, b) => b.top.compareTo(a.top));
    final result = <PdfTextLine>[];
    final leftColumn = <PdfTextLine>[];
    final rightColumn = <PdfTextLine>[];
    void flushColumns() {
      result
        ..addAll(leftColumn)
        ..addAll(rightColumn);
      leftColumn.clear();
      rightColumn.clear();
    }

    for (final line in sorted) {
      if (line.right <= gutter) {
        leftColumn.add(line);
      } else if (line.left >= gutter) {
        rightColumn.add(line);
      } else {
        flushColumns();
        result.add(line);
      }
    }
    flushColumns();
    return result;
  }

  /// The x position of a column gutter, or null for single-column pages.
  double? findGutter(List<PdfTextLine> lines, double pageWidth) {
    if (lines.length < 8 || pageWidth <= 0) return null;
    double? best;
    double? bandStart;
    var bestCrossing = 1 << 30;
    var extending = false;
    for (var x = pageWidth * 0.3; x <= pageWidth * 0.7; x += 2) {
      var crossing = 0;
      var leftCount = 0;
      var rightCount = 0;
      var leftWidth = 0.0;
      var rightWidth = 0.0;
      for (final line in lines) {
        if (line.right <= x) {
          leftCount++;
          leftWidth += line.width;
        } else if (line.left >= x) {
          rightCount++;
          rightWidth += line.width;
        } else {
          crossing++;
        }
      }
      if (leftCount < 4 || rightCount < 4) {
        extending = false;
        continue;
      }
      // Both sides must hold real text columns, not a strip of page
      // numbers in a table of contents.
      if (leftWidth / leftCount < pageWidth * 0.22 ||
          rightWidth / rightCount < pageWidth * 0.22) {
        extending = false;
        continue;
      }
      if (crossing < bestCrossing) {
        bestCrossing = crossing;
        bandStart = x;
        best = x;
      } else if (crossing == bestCrossing && extending) {
        // Extend the empty band; the gutter is its middle.
        best = x;
      }
      extending = crossing == bestCrossing;
    }
    if (best != null && bandStart != null) best = (bandStart + best) / 2;
    if (best == null) return null;
    if (bestCrossing > lines.length * 0.2) return null;
    final gutter = best;
    // The columns must sit side by side for a good part of the page.
    final leftLines = lines.where((line) => line.right <= gutter);
    final rightLines = lines.where((line) => line.left >= gutter);
    final leftTop = leftLines.map((line) => line.top).reduce(math.max);
    final leftBottom = leftLines.map((line) => line.bottom).reduce(math.min);
    final rightTop = rightLines.map((line) => line.top).reduce(math.max);
    final rightBottom = rightLines.map((line) => line.bottom).reduce(math.min);
    final overlap =
        math.min(leftTop, rightTop) - math.max(leftBottom, rightBottom);
    final span =
        math.max(leftTop, rightTop) - math.min(leftBottom, rightBottom);
    if (span <= 0 || overlap / span < 0.3) return null;
    return gutter;
  }
}
