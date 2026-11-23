/// A downloadable dictionary language. Packs come from kaikki.org's
/// per-language extracts of English Wiktionary: glosses in English for
/// words of that language, with inflected forms linked to their headwords.
class DictionaryLanguage {
  const DictionaryLanguage({
    required this.code,
    required this.name,
    required this.nativeName,
    required this.downloadBytes,
  });

  /// ISO 639-1 code, as used in EPUB `dc:language`.
  final String code;
  final String name;
  final String nativeName;

  /// Size of the compressed download (checked November 2026; the real size
  /// comes from the server when downloading).
  final int downloadBytes;

  /// kaikki.org names its files after the English language name.
  Uri get downloadUri => Uri.parse(
    'https://kaikki.org/dictionary/$name/kaikki.org-dictionary-$name.jsonl.gz',
  );
}

const englishLanguage = DictionaryLanguage(
  code: 'en',
  name: 'English',
  nativeName: 'English',
  downloadBytes: 0,
);

/// Languages offered for download. Only space-separated scripts: tapping a
/// word in Chinese or Japanese text does not select a dictionary word.
/// Finnish (270 MB) and Chinese (155 MB) are left out as too large.
const downloadableLanguages = <DictionaryLanguage>[
  DictionaryLanguage(
    code: 'ar',
    name: 'Arabic',
    nativeName: 'العربية',
    downloadBytes: 72370936,
  ),
  DictionaryLanguage(
    code: 'ca',
    name: 'Catalan',
    nativeName: 'Català',
    downloadBytes: 23673149,
  ),
  DictionaryLanguage(
    code: 'cs',
    name: 'Czech',
    nativeName: 'Čeština',
    downloadBytes: 24290587,
  ),
  DictionaryLanguage(
    code: 'da',
    name: 'Danish',
    nativeName: 'Dansk',
    downloadBytes: 11685254,
  ),
  DictionaryLanguage(
    code: 'de',
    name: 'German',
    nativeName: 'Deutsch',
    downloadBytes: 99294210,
  ),
  DictionaryLanguage(
    code: 'el',
    name: 'Greek',
    nativeName: 'Ελληνικά',
    downloadBytes: 25208708,
  ),
  DictionaryLanguage(
    code: 'es',
    name: 'Spanish',
    nativeName: 'Español',
    downloadBytes: 102536460,
  ),
  DictionaryLanguage(
    code: 'fa',
    name: 'Persian',
    nativeName: 'فارسی',
    downloadBytes: 13640867,
  ),
  DictionaryLanguage(
    code: 'fr',
    name: 'French',
    nativeName: 'Français',
    downloadBytes: 59206544,
  ),
  DictionaryLanguage(
    code: 'he',
    name: 'Hebrew',
    nativeName: 'עברית',
    downloadBytes: 8786413,
  ),
  DictionaryLanguage(
    code: 'hi',
    name: 'Hindi',
    nativeName: 'हिन्दी',
    downloadBytes: 18286006,
  ),
  DictionaryLanguage(
    code: 'hu',
    name: 'Hungarian',
    nativeName: 'Magyar',
    downloadBytes: 54589180,
  ),
  DictionaryLanguage(
    code: 'id',
    name: 'Indonesian',
    nativeName: 'Bahasa Indonesia',
    downloadBytes: 10749713,
  ),
  DictionaryLanguage(
    code: 'it',
    name: 'Italian',
    nativeName: 'Italiano',
    downloadBytes: 76647674,
  ),
  DictionaryLanguage(
    code: 'la',
    name: 'Latin',
    nativeName: 'Latina',
    downloadBytes: 110190447,
  ),
  DictionaryLanguage(
    code: 'nl',
    name: 'Dutch',
    nativeName: 'Nederlands',
    downloadBytes: 30804351,
  ),
  DictionaryLanguage(
    code: 'pl',
    name: 'Polish',
    nativeName: 'Polski',
    downloadBytes: 89394855,
  ),
  DictionaryLanguage(
    code: 'pt',
    name: 'Portuguese',
    nativeName: 'Português',
    downloadBytes: 60132567,
  ),
  DictionaryLanguage(
    code: 'ro',
    name: 'Romanian',
    nativeName: 'Română',
    downloadBytes: 39931394,
  ),
  DictionaryLanguage(
    code: 'ru',
    name: 'Russian',
    nativeName: 'Русский',
    downloadBytes: 90794686,
  ),
  DictionaryLanguage(
    code: 'sv',
    name: 'Swedish',
    nativeName: 'Svenska',
    downloadBytes: 34178064,
  ),
  DictionaryLanguage(
    code: 'tr',
    name: 'Turkish',
    nativeName: 'Türkçe',
    downloadBytes: 38129580,
  ),
  DictionaryLanguage(
    code: 'uk',
    name: 'Ukrainian',
    nativeName: 'Українська',
    downloadBytes: 36040429,
  ),
];

DictionaryLanguage? languageByCode(String? code) {
  if (code == null) return null;
  if (code == englishLanguage.code) return englishLanguage;
  for (final language in downloadableLanguages) {
    if (language.code == code) return language;
  }
  return null;
}

/// ISO 639-2 codes some EPUBs use instead of 639-1.
const _threeLetter = {
  'eng': 'en',
  'ara': 'ar',
  'cat': 'ca',
  'ces': 'cs',
  'cze': 'cs',
  'dan': 'da',
  'deu': 'de',
  'ger': 'de',
  'ell': 'el',
  'gre': 'el',
  'spa': 'es',
  'fas': 'fa',
  'per': 'fa',
  'fra': 'fr',
  'fre': 'fr',
  'heb': 'he',
  'hin': 'hi',
  'hun': 'hu',
  'ind': 'id',
  'ita': 'it',
  'lat': 'la',
  'nld': 'nl',
  'dut': 'nl',
  'pol': 'pl',
  'por': 'pt',
  'ron': 'ro',
  'rum': 'ro',
  'rus': 'ru',
  'swe': 'sv',
  'tur': 'tr',
  'ukr': 'uk',
};

const _names = {
  'english': 'en',
  'french': 'fr',
  'german': 'de',
  'spanish': 'es',
  'italian': 'it',
  'portuguese': 'pt',
  'dutch': 'nl',
  'russian': 'ru',
};

/// Turns an EPUB or HTML language tag ("fr-FR", "fre", "English", "iw")
/// into a two-letter code, or null when it is empty or unknown.
String? normalizeLanguageCode(String? tag) {
  if (tag == null) return null;
  final primary = tag.trim().toLowerCase().split(RegExp('[-_ ]')).first;
  if (primary.isEmpty) return null;
  if (primary == 'iw') return 'he';
  if (primary == 'in') return 'id';
  if (primary.length == 2 && RegExp(r'^[a-z]{2}$').hasMatch(primary)) {
    return primary;
  }
  return _threeLetter[primary] ?? _names[tag.trim().toLowerCase()];
}
