import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app_messenger.dart';
import 'core/sync/sync_providers.dart';
import 'firebase_options.dart';
import 'design/brutal_theme.dart';
import 'features/achievements/data/achievement_service.dart';
import 'features/social/data/social_providers.dart';
import 'providers/settings_providers.dart';
import 'screens/auth_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _initializeFirebase();

  runApp(
    ProviderScope(
      overrides: appProviderOverrides,
      child: const BookmunityApp(),
    ),
  );
}

/// Connects modules that must not import each other directly.
final appProviderOverrides = [
  badgeUnlockListenersProvider.overrideWith(socialBadgeListeners),
  currentUidProvider.overrideWith(_signedInUid),
  syncRestoredListenersProvider.overrideWith(_afterRestore),
];

/// Per-account data (database file, settings, sync) follows Firebase Auth.
/// Until the auth stream reports, the persisted user is used so the right
/// library and theme show from the first frame.
String? _signedInUid(Ref ref) {
  if (!ref.watch(firebaseReadyProvider)) return null;
  final auth = ref.watch(authUserProvider);
  return auth.hasValue
      ? auth.value?.uid
      : FirebaseAuth.instance.currentUser?.uid;
}

/// After the cloud library is merged in (e.g. on a new device), award any
/// badges the restored data implies and refresh the public profile stats.
List<Future<void> Function()> _afterRestore(Ref ref) => [
  () async {
    final service = await ref.read(achievementServiceProvider.future);
    await checkAchievementsWith(
      service,
      ref.read(badgeUnlockListenersProvider),
      announce: false,
    );
    await ref.read(socialActivityProvider).syncProfileStats();
  },
];

Future<void> _initializeFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } on UnsupportedError {
    // Firebase options are not configured for Linux yet.
  }
}

class BookmunityApp extends ConsumerWidget {
  const BookmunityApp({this.home = const AuthGate(), super.key});

  final Widget home;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Bookmunity',
      scaffoldMessengerKey: appMessengerKey,
      theme: brutalTheme(dark: false),
      darkTheme: brutalTheme(dark: true),
      themeMode: ref.watch(appThemeModeProvider),
      home: home,
    );
  }
}
