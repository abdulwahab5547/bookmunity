import 'package:bookmunity/features/reader/presentation/widgets/selection_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final initial in [null, '', 'old note']) {
    testWidgets('note dialog saves and closes cleanly (initial: $initial)', (
      tester,
    ) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showNoteDialog(
                  context,
                  initial: initial,
                  quote: 'It is a truth universally acknowledged',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'my thoughts');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result, 'my thoughts');
      expect(tester.takeException(), isNull);
    });
  }
}
