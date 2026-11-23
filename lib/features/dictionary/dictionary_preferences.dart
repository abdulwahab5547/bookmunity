import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'language_catalog.dart';

/// The reader's dictionary choices. Settings sync stores [toJson] in
/// `users/{uid}/private/settings` and applies a synced copy with
/// [DictionaryPreferencesNotifier.applyJson].
class DictionaryPreferences {
  const DictionaryPreferences({this.languages = const {}, this.lookupLanguage});

  /// Languages the reader chose to download. A pack may be missing on this
  /// device (for example after syncing from another phone); the
  /// Dictionaries screen then offers to download it again.
  final Set<String> languages;

  /// Language to look words up in, or null to follow each book's language.
  final String? lookupLanguage;

  DictionaryPreferences copyWith({
    Set<String>? languages,
    String? Function()? lookupLanguage,
  }) => DictionaryPreferences(
    languages: languages ?? this.languages,
    lookupLanguage: lookupLanguage == null
        ? this.lookupLanguage
        : lookupLanguage(),
  );

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

class DictionaryPreferencesNotifier
    extends StateNotifier<DictionaryPreferences> {
  DictionaryPreferencesNotifier() : super(const DictionaryPreferences());

  static const storageKey = 'dictionary_preferences';

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(storageKey);
    if (!mounted || raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        state = DictionaryPreferences.fromJson(
          Map<String, Object?>.from(decoded),
        );
      }
    } on FormatException {
      // Keep defaults.
    }
  }

  /// Replaces the preferences with a synced copy.
  Future<void> applyJson(Map<String, Object?> json) =>
      _set(DictionaryPreferences.fromJson(json));

  Future<void> setLookupLanguage(String? code) =>
      _set(state.copyWith(lookupLanguage: () => code));

  Future<void> addLanguage(String code) =>
      _set(state.copyWith(languages: {...state.languages, code}));

  Future<void> removeLanguage(String code) => _set(
    state.copyWith(
      languages: {...state.languages}..remove(code),
      lookupLanguage: state.lookupLanguage == code ? () => null : null,
    ),
  );

  Future<void> _set(DictionaryPreferences next) async {
    if (next == state) return;
    state = next;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(storageKey, jsonEncode(next.toJson()));
  }
}

final dictionaryPreferencesProvider =
    StateNotifierProvider<DictionaryPreferencesNotifier, DictionaryPreferences>(
      (ref) => DictionaryPreferencesNotifier()..load(),
    );
