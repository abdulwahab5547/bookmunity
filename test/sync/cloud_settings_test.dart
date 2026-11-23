import 'package:bookmunity/core/sync/cloud_settings.dart';
import 'package:bookmunity/core/sync/remote_store.dart';
import 'package:bookmunity/providers/settings_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_sync_store.dart';

void main() {
  late FakeSyncStore store;
  final controllers = <CloudSettingsController>[];

  Future<CloudSettingsController> open(
    String scope, {
    bool cloud = true,
  }) async {
    final controller = CloudSettingsController(
      scope: scope,
      store: cloud ? store : null,
      pushDelay: const Duration(milliseconds: 10),
    );
    controllers.add(controller);
    await controller.load();
    await settle(3);
    return controller;
  }

  Map<String, Object?> remoteValues() =>
      (store.doc(SyncCollections.private, 'settings')?['values'] as Map?)
          ?.cast<String, Object?>() ??
      const {};

  setUp(() => store = FakeSyncStore());
  tearDown(() {
    for (final controller in controllers) {
      if (controller.mounted) controller.dispose();
    }
    controllers.clear();
  });

  test(
    'old SharedPreferences settings are imported once and uploaded',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader_font_size': 24.0,
        'reader_theme': 'sepia',
        'app_theme_mode': 'dark',
        'share_activity': false,
        'library_grid': false,
      });
      final first = await open('alice');
      expect(first.state.get<double>('reader_font_size'), 24.0);
      expect(SettingsNotifier.fromMap(first.state).theme, ReaderTheme.sepia);
      expect(remoteValues(), {
        'reader_font_size': 24.0,
        'reader_theme': 'sepia',
        'app_theme_mode': 'dark',
        'share_activity': false,
        'library_grid': false,
      });

      // A second account on the same device does not inherit them.
      final second = await open('bob', cloud: false);
      expect(second.state.values, isEmpty);
    },
  );

  test('a new device gets the settings from the cloud', () async {
    SharedPreferences.setMockInitialValues({});
    final phone = await open('alice');
    phone.setAll({'reader_font_size': 21.0, 'app_theme_mode': 'dark'});
    await settle(3);

    // Reinstall: empty preferences, same account.
    SharedPreferences.setMockInitialValues({});
    final reinstalled = await open('alice');
    expect(reinstalled.state.get<double>('reader_font_size'), 21.0);
    expect(reinstalled.state.get<String>('app_theme_mode'), 'dark');
    expect(reinstalled.state.values.containsKey('reader_theme'), isFalse);
  });

  test('each key merges on its own: newer value wins', () async {
    SharedPreferences.setMockInitialValues({});
    final phone = await open('alice');
    // Another device on the same account: same store, its own local cache
    // (a different cache scope stands in for a different device).
    final tabletOnSameAccount = await open('alice-on-tablet');

    phone.set('reader_theme', 'dark');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    tabletOnSameAccount.set('reader_font_size', 26.0);
    await settle(4);

    for (final device in [phone, tabletOnSameAccount]) {
      expect(device.state.get<String>('reader_theme'), 'dark');
      expect(device.state.get<double>('reader_font_size'), 26.0);
    }

    tabletOnSameAccount.set('reader_theme', 'sepia');
    await settle(4);
    expect(phone.state.get<String>('reader_theme'), 'sepia');
  });

  test('unknown keys from other features round-trip untouched', () async {
    SharedPreferences.setMockInitialValues({});
    final phone = await open('alice');
    phone.set('dictionary_languages', ['en', 'ur']);
    await settle(3);
    SharedPreferences.setMockInitialValues({});
    final other = await open('alice');
    expect(other.state.get<List>('dictionary_languages'), ['en', 'ur']);
  });

  test('settings survive restarts through the local cache', () async {
    SharedPreferences.setMockInitialValues({});
    final offline = await open('local', cloud: false);
    offline.set('app_theme_mode', 'light');
    await settle(2);
    offline.dispose();
    final again = await open('local', cloud: false);
    expect(again.state.get<String>('app_theme_mode'), 'light');
  });

  test('typed reader settings write only what changed', () async {
    SharedPreferences.setMockInitialValues({});
    final phone = await open('alice');
    final notifier = SettingsNotifier(phone)..apply(phone.state);
    await notifier.update(notifier.state.copyWith(fontSize: 22));
    expect(phone.state.values.keys, ['reader_font_size']);
    final theme = AppThemeModeNotifier(phone);
    await theme.set(ThemeMode.dark);
    expect(phone.state.get<String>('app_theme_mode'), 'dark');
    notifier.dispose();
    theme.dispose();
  });
}
