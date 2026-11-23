import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sync/cloud_settings.dart';

// Reader and app settings live in the account's cloud settings map
// (`users/{uid}/private/settings`, cached on the device). These notifiers are
// typed views over it; the keys are the ones previously used in
// SharedPreferences, which are imported once on upgrade.

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, ReaderSettings>((ref) {
      final store = ref.watch(cloudSettingsProvider.notifier);
      final notifier = SettingsNotifier(store)
        ..apply(ref.read(cloudSettingsProvider));
      ref.listen(cloudSettingsProvider, (_, next) => notifier.apply(next));
      return notifier;
    });

final appThemeModeProvider =
    StateNotifierProvider<AppThemeModeNotifier, ThemeMode>((ref) {
      final store = ref.watch(cloudSettingsProvider.notifier);
      final notifier = AppThemeModeNotifier(store)
        ..apply(ref.read(cloudSettingsProvider));
      ref.listen(cloudSettingsProvider, (_, next) => notifier.apply(next));
      return notifier;
    });

enum ReaderFlow { paginated, scrolled }

enum ReaderTheme { light, sepia, dark }

enum ReaderFont { serif, sans }

enum ReaderOrientation { auto, portrait, landscape }

class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 19,
    this.lineHeight = 1.6,
    this.margin = 20,
    this.theme = ReaderTheme.light,
    this.flow = ReaderFlow.paginated,
    this.font = ReaderFont.serif,
    this.keepScreenAwake = true,
    this.orientation = ReaderOrientation.auto,
  });

  static const minFontSize = 14.0;
  static const maxFontSize = 30.0;
  static const minLineHeight = 1.2;
  static const maxLineHeight = 2.2;
  static const minMargin = 8.0;
  static const maxMargin = 48.0;

  final double fontSize;
  final double lineHeight;
  final double margin;
  final ReaderTheme theme;
  final ReaderFlow flow;
  final ReaderFont font;
  final bool keepScreenAwake;
  final ReaderOrientation orientation;

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    double? margin,
    ReaderTheme? theme,
    ReaderFlow? flow,
    ReaderFont? font,
    bool? keepScreenAwake,
    ReaderOrientation? orientation,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      margin: margin ?? this.margin,
      theme: theme ?? this.theme,
      flow: flow ?? this.flow,
      font: font ?? this.font,
      keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
      orientation: orientation ?? this.orientation,
    );
  }

  /// The shape the JavaScript reader expects.
  Map<String, Object> toReaderJson() => {
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'margin': margin,
    'theme': theme.name,
    'flow': flow.name,
    'font': font.name,
  };

  @override
  bool operator ==(Object other) =>
      other is ReaderSettings &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.margin == margin &&
      other.theme == theme &&
      other.flow == flow &&
      other.font == font &&
      other.keepScreenAwake == keepScreenAwake &&
      other.orientation == orientation;

  @override
  int get hashCode => Object.hash(
    fontSize,
    lineHeight,
    margin,
    theme,
    flow,
    font,
    keepScreenAwake,
    orientation,
  );
}

T _enumByName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

class SettingsNotifier extends StateNotifier<ReaderSettings> {
  SettingsNotifier([this._store]) : super(const ReaderSettings());

  final CloudSettingsController? _store;

  static const _fontSize = 'reader_font_size';
  static const _lineHeight = 'reader_line_height';
  static const _margin = 'reader_margin';
  static const _theme = 'reader_theme';
  static const _flow = 'reader_flow';
  static const _font = 'reader_font';
  static const _keepAwake = 'reader_keep_awake';
  static const _orientation = 'reader_orientation';

  /// Reads the typed settings out of the generic map.
  static ReaderSettings fromMap(CloudSettings settings) {
    const defaults = ReaderSettings();
    double number(String key, double fallback, double min, double max) =>
        (settings.get<num>(key)?.toDouble() ?? fallback).clamp(min, max);
    return ReaderSettings(
      fontSize: number(
        _fontSize,
        defaults.fontSize,
        ReaderSettings.minFontSize,
        ReaderSettings.maxFontSize,
      ),
      lineHeight: number(
        _lineHeight,
        defaults.lineHeight,
        ReaderSettings.minLineHeight,
        ReaderSettings.maxLineHeight,
      ),
      margin: number(
        _margin,
        defaults.margin,
        ReaderSettings.minMargin,
        ReaderSettings.maxMargin,
      ),
      theme: _enumByName(
        ReaderTheme.values,
        settings.get<String>(_theme),
        defaults.theme,
      ),
      flow: _enumByName(
        ReaderFlow.values,
        settings.get<String>(_flow),
        defaults.flow,
      ),
      font: _enumByName(
        ReaderFont.values,
        settings.get<String>(_font),
        defaults.font,
      ),
      keepScreenAwake:
          settings.get<bool>(_keepAwake) ?? defaults.keepScreenAwake,
      orientation: _enumByName(
        ReaderOrientation.values,
        settings.get<String>(_orientation),
        defaults.orientation,
      ),
    );
  }

  void apply(CloudSettings settings) {
    final next = fromMap(settings);
    if (mounted && next != state) state = next;
  }

  static Map<String, Object> _toMap(ReaderSettings settings) => {
    _fontSize: settings.fontSize,
    _lineHeight: settings.lineHeight,
    _margin: settings.margin,
    _theme: settings.theme.name,
    _flow: settings.flow.name,
    _font: settings.font.name,
    _keepAwake: settings.keepScreenAwake,
    _orientation: settings.orientation.name,
  };

  /// Saves only the settings that changed, so another device's edit to a
  /// different setting is not overwritten.
  Future<void> update(ReaderSettings next) async {
    final before = _toMap(state);
    state = next;
    final changed = {
      for (final entry in _toMap(next).entries)
        if (before[entry.key] != entry.value) entry.key: entry.value,
    };
    if (changed.isNotEmpty) _store?.setAll(changed);
  }
}

class AppThemeModeNotifier extends StateNotifier<ThemeMode> {
  AppThemeModeNotifier([this._store]) : super(ThemeMode.system);

  final CloudSettingsController? _store;

  static const _key = 'app_theme_mode';

  void apply(CloudSettings settings) {
    final next = _enumByName(
      ThemeMode.values,
      settings.get<String>(_key),
      ThemeMode.system,
    );
    if (mounted && next != state) state = next;
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    _store?.set(_key, mode.name);
  }
}
