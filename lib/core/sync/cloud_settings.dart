import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_store.dart';
import 'sync_providers.dart';

/// Settings as a generic key/value map, stored in
/// `users/{uid}/private/settings` and cached locally so first paint does
/// not wait for the network.
///
/// Any feature can add keys (JSON-compatible values: bool, num, String,
/// lists and maps of those):
///
/// ```dart
/// final languages = ref.watch(cloudSettingsProvider).get<List>('dictionary_languages');
/// ref.read(cloudSettingsProvider.notifier).set('dictionary_languages', ['en']);
/// ```
///
/// Each key carries its own edit time and the newer value wins, so two
/// devices changing different settings never overwrite each other.
class CloudSettings {
  const CloudSettings({
    this.values = const {},
    this.stamps = const {},
    this.loaded = false,
  });

  final Map<String, Object?> values;

  /// Edit time per key, milliseconds since the epoch.
  final Map<String, int> stamps;

  /// False until the local cache has been read.
  final bool loaded;

  T? get<T>(String key) {
    final value = values[key];
    return value is T ? value : null;
  }
}

/// Keys this app stored in SharedPreferences before settings moved to the
/// cloud. They are imported once per device with the oldest possible stamp,
/// so a value already in the cloud wins.
const legacySettingKeys = [
  'reader_font_size',
  'reader_line_height',
  'reader_margin',
  'reader_theme',
  'reader_flow',
  'reader_font',
  'reader_keep_awake',
  'reader_orientation',
  'app_theme_mode',
  'share_activity',
  'library_grid',
];

class CloudSettingsController extends StateNotifier<CloudSettings> {
  CloudSettingsController({
    required this.scope,
    this.store,
    this.pushDelay = const Duration(seconds: 1),
  }) : super(const CloudSettings());

  static const docId = 'settings';
  static const _legacyClaimedKey = 'cloud_settings_legacy_claimed';

  /// The account uid, or `local` when signed out.
  final String scope;
  final SyncStore? store;
  final Duration pushDelay;

  final Set<String> _pending = {};
  StreamSubscription<RemoteSnapshot>? _subscription;
  Timer? _pushTimer;
  Future<void>? _loading;

  String get _cacheKey => 'cloud_settings.$scope';

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    final values = <String, Object?>{};
    final stamps = <String, int>{};
    final cached = preferences.getString(_cacheKey);
    if (cached != null) {
      try {
        final json = jsonDecode(cached) as Map<String, dynamic>;
        values.addAll((json['values'] as Map).cast<String, Object?>());
        stamps.addAll((json['stamps'] as Map).cast<String, int>());
        _pending.addAll((json['pending'] as List).cast<String>());
      } catch (error) {
        debugPrint('Settings cache unreadable: $error');
      }
    } else if (preferences.getBool(_legacyClaimedKey) != true) {
      for (final key in legacySettingKeys) {
        final value = preferences.get(key);
        if (value == null) continue;
        values[key] = value;
        stamps[key] = 1;
        _pending.add(key);
      }
      await preferences.setBool(_legacyClaimedKey, true);
    }
    if (!mounted) return;
    state = CloudSettings(values: values, stamps: stamps, loaded: true);
    await _saveCache();
    if (!mounted) return;
    _subscription = store
        ?.watch(SyncCollections.private)
        .listen(
          _onRemote,
          onError: (Object error) =>
              debugPrint('Settings listener failed: $error'),
        );
    if (_pending.isNotEmpty) _schedulePush();
  }

  void set(String key, Object? value) => setAll({key: value});

  void setAll(Map<String, Object?> entries) {
    final now = DateTime.now().millisecondsSinceEpoch;
    state = CloudSettings(
      values: {...state.values, ...entries},
      stamps: {...state.stamps, for (final key in entries.keys) key: now},
      loaded: state.loaded,
    );
    _pending.addAll(entries.keys);
    unawaited(_saveCache(state));
    _schedulePush();
  }

  void _onRemote(RemoteSnapshot snapshot) {
    for (final doc in snapshot.docs) {
      if (doc.id == docId) _merge(doc);
    }
  }

  void _merge(RemoteDoc doc) {
    final remoteValues = doc.data['values'];
    final remoteStamps = doc.data['stamps'];
    if (remoteValues is! Map || remoteStamps is! Map) return;
    final values = {...state.values};
    final stamps = {...state.stamps};
    var changed = false;
    for (final entry in remoteValues.entries) {
      final key = entry.key as String;
      final stamp = remoteStamps[key];
      final remoteAt = stamp is DateTime ? stamp.millisecondsSinceEpoch : 0;
      final localAt = stamps[key] ?? 0;
      if (remoteAt > localAt) {
        values[key] = entry.value;
        stamps[key] = remoteAt;
        _pending.remove(key);
        changed = true;
      } else if (localAt > remoteAt) {
        _pending.add(key);
      }
    }
    for (final key in values.keys) {
      if (!remoteValues.containsKey(key)) _pending.add(key);
    }
    if (changed && mounted) {
      state = CloudSettings(values: values, stamps: stamps, loaded: true);
    }
    if (!mounted) return;
    unawaited(_saveCache(state));
    if (_pending.isNotEmpty) _schedulePush();
  }

  void _schedulePush() {
    if (store == null) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(pushDelay, () => unawaited(push()));
  }

  /// Sends pending keys now. The document is merged, so keys written by
  /// other features or devices are left alone.
  Future<void> push() async {
    final target = store;
    if (target == null || _pending.isEmpty) return;
    final sent = state;
    final keys = _pending.toList();
    final stamps = {for (final key in keys) key: sent.stamps[key] ?? 0};
    final write = RemoteWrite(SyncCollections.private, docId, {
      'values': {for (final key in keys) key: sent.values[key]},
      'stamps': {
        for (final key in keys)
          key: DateTime.fromMillisecondsSinceEpoch(stamps[key]!),
      },
      'updatedAt': DateTime.now(),
    }, merge: true);
    final future = target.commit([write]);
    void accept() {
      final current = mounted ? state : sent;
      for (final key in keys) {
        if (current.stamps[key] == stamps[key]) _pending.remove(key);
      }
    }

    try {
      await future.timeout(const Duration(seconds: 10));
      accept();
    } on TimeoutException {
      // Queued by the offline cache.
      accept();
    } catch (error) {
      debugPrint('Settings not synced: $error');
    }
    await _saveCache(mounted ? state : sent);
  }

  Future<void> _saveCache([CloudSettings? snapshot]) async {
    final settings = snapshot ?? state;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _cacheKey,
      jsonEncode({
        'values': settings.values,
        'stamps': settings.stamps,
        'pending': _pending.toList(),
      }),
    );
  }

  @override
  void dispose() {
    _pushTimer?.cancel();
    _subscription?.cancel();
    if (_pending.isNotEmpty) unawaited(push());
    super.dispose();
  }
}

final cloudSettingsProvider =
    StateNotifierProvider<CloudSettingsController, CloudSettings>((ref) {
      final uid = ref.watch(currentUidProvider);
      final controller = CloudSettingsController(
        scope: uid ?? 'local',
        store: ref.watch(syncStoreProvider),
      );
      unawaited(controller.load());
      return controller;
    });
