import 'dart:math' as math;

import 'package:bookmunity/features/reader/domain/reader_palette.dart';
import 'package:bookmunity/providers/settings_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final readerTheme in ReaderTheme.values) {
    test('${readerTheme.name} reader text is readable on its panels', () {
      final palette = ReaderPalette.of(readerTheme);
      final theme = palette.theme();
      final panel = theme.bottomSheetTheme.backgroundColor!;
      expect(panel, palette.panel);
      expect(theme.colorScheme.surfaceContainerLow, palette.panel);
      for (final style in [
        theme.textTheme.bodyMedium,
        theme.textTheme.titleMedium,
        theme.textTheme.headlineSmall,
      ]) {
        expect(_contrast(style!.color!, panel), greaterThan(7));
      }
      // Secondary text (part of speech, examples) still meets WCAG AA.
      expect(
        _contrast(theme.textTheme.bodySmall!.color!, panel),
        greaterThan(3),
      );
    });
  }
}
