import 'package:bookmunity/design/brutal_theme.dart';
import 'package:bookmunity/screens/google_sign_in_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap({required bool dark}) => MaterialApp(
  theme: brutalTheme(dark: dark),
  home: const Scaffold(
    body: SizedBox(width: 320, child: GoogleSignInSection()),
  ),
);

void main() {
  testWidgets('shows Continue with Google on Android at 320dp', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(_wrap(dark: dark));
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.byType(GoogleLogo), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('hidden on platforms without Google sign-in', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_wrap(dark: false));
    expect(find.text('Continue with Google'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
