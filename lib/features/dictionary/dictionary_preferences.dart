import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync/cloud_settings.dart';
import 'language_catalog.dart';

/// The reader's dictionary choices, stored in the synced settings under
/// `dictionary.` keys (see [DictionaryPreferences.settingsKeys]).
class DictionaryPreferences {
  const DictionaryPreferences({this.languages = const {}, this.lookupLanguage});

  /// Languages the reader chose to download. A pack may be missing on this
  /// device (for example after syncing from another phone); the
  /// Dictionaries screen then offers to download it again.
  final Set<String> languages;

  /// Language to look words up in, or null to follow each book's language.
  final String? lookupLanguage;

  static const languagesKey = 'dictionary.languages';
  static const lookupLanguageKey = 'dictionary.lookupLanguage';
  static const settingsKeys = [languagesKey, lookupLanguageKey];

  Map<String, Object?> toJson() => {
    'languages': (languages.toList()..sort()),
    'lookupLanguage': lookupLanguage,
  };

  factory DictionaryPreferences.fromJson(Map<String, Object?> json) {
    final rawLanguages = json['languages'];
    final lookup = json['lookupLanguage'];
    return DictionaryPreferences(
      languages: {
        if (rawLanguages is List)
          for (final code in rawLanguages)
            if (code is String && languageByCode(code) != null && code != 'en')
              code,
      },
      lookupLanguage: lookup is String && languageByCode(lookup) != null
          ? lookup
          : null,
    );
  }

  /// Reads the `dictionary.` keys of the synced settings.
  factory DictionaryPreferences.fromSettings(CloudSettings settings) =>
      DictionaryPreferences.fromJson({
        'languages': settings.values[languagesKey],
        'lookupLanguage': settings.values[lookupLanguageKey],
      });

  /// The synced-settings entries for these preferences.
  Map<String, Object?> toSettings() {
    final json = toJson();
    return {
      languagesKey: json['languages'],
      lookupLanguageKey: json['lookupLanguage'],
    };
  }

  @override
  bool operator ==(Object other) =>
      other is DictionaryPreferences &&
      other.lookupLanguage == lookupLanguage &&
      other.languages.length == languages.length &&
      other.languages.containsAll(languages);

  @override
  int get hashCode =>
      Object.hash(lookupLanguage, Object.hashAllUnordered(languages));
}

/// Current preferences; rebuilds only when they change.
final dictionaryPreferencesProvider = Provider<DictionaryPreferences>(
  (ref) => DictionaryPreferences.fromSettings(ref.watch(cloudSettingsProvider)),
);

/// Writes dictionary preferences through the synced settings.
class DictionaryPreferencesController {
  DictionaryPreferencesController(this._ref);

  final Ref _ref;

  DictionaryPreferences get _current =>
      _ref.read(dictionaryPreferencesProvider);

  void setLookupLanguage(String? code) => _ref
      .read(cloudSettingsProvider.notifier)
      .set(DictionaryPreferences.lookupLanguageKey, code);

  void addLanguage(String code) {
    final languages = {..._current.languages, code}.toList()..sort();
    _ref
        .read(cloudSettingsProvider.notifier)
        .set(DictionaryPreferences.languagesKey, languages);
  }

  void removeLanguage(String code) {
    final current = _current;
    final languages = {...current.languages}..remove(code);
    _ref.read(cloudSettingsProvider.notifier).setAll({
      DictionaryPreferences.languagesKey: languages.toList()..sort(),
      if (current.lookupLanguage == code)
        DictionaryPreferences.lookupLanguageKey: null,
    });
  }
}

final dictionaryPreferencesControllerProvider =
    Provider<DictionaryPreferencesController>(
      DictionaryPreferencesController.new,
    );
