/// The languages whisper can transcribe, and the small amount of normalisation
/// the three backends need to agree on.
///
/// Codes are whisper's own (ISO 639-1, plus `haw`, `jw`, `nn`, `yue` where
/// whisper has no two-letter code). A take can hold more than one language, so
/// the person's answer is a *list*, in the order they picked it: the first entry
/// is what gets forced when whisper's own guess lands outside the list.
library;

/// Code → English name, in whisper's order. A const map keeps its insertion
/// order, so the picker lists languages the same way everywhere.
const Map<String, String> whisperLanguages = {
  'af': 'Afrikaans',
  'am': 'Amharic',
  'ar': 'Arabic',
  'as': 'Assamese',
  'az': 'Azerbaijani',
  'ba': 'Bashkir',
  'be': 'Belarusian',
  'bg': 'Bulgarian',
  'bn': 'Bengali',
  'bo': 'Tibetan',
  'br': 'Breton',
  'bs': 'Bosnian',
  'ca': 'Catalan',
  'cs': 'Czech',
  'cy': 'Welsh',
  'da': 'Danish',
  'de': 'German',
  'el': 'Greek',
  'en': 'English',
  'es': 'Spanish',
  'et': 'Estonian',
  'eu': 'Basque',
  'fa': 'Persian',
  'fi': 'Finnish',
  'fo': 'Faroese',
  'fr': 'French',
  'gl': 'Galician',
  'gu': 'Gujarati',
  'ha': 'Hausa',
  'haw': 'Hawaiian',
  'he': 'Hebrew',
  'hi': 'Hindi',
  'hr': 'Croatian',
  'ht': 'Haitian Creole',
  'hu': 'Hungarian',
  'hy': 'Armenian',
  'id': 'Indonesian',
  'is': 'Icelandic',
  'it': 'Italian',
  'ja': 'Japanese',
  'jw': 'Javanese',
  'ka': 'Georgian',
  'kk': 'Kazakh',
  'km': 'Khmer',
  'kn': 'Kannada',
  'ko': 'Korean',
  'la': 'Latin',
  'lb': 'Luxembourgish',
  'lo': 'Lao',
  'lt': 'Lithuanian',
  'lv': 'Latvian',
  'mg': 'Malagasy',
  'mi': 'Maori',
  'mk': 'Macedonian',
  'ml': 'Malayalam',
  'mn': 'Mongolian',
  'mr': 'Marathi',
  'ms': 'Malay',
  'mt': 'Maltese',
  'my': 'Burmese',
  'ne': 'Nepali',
  'nl': 'Dutch',
  'nn': 'Nynorsk',
  'no': 'Norwegian',
  'oc': 'Occitan',
  'pa': 'Punjabi',
  'pl': 'Polish',
  'ps': 'Pashto',
  'pt': 'Portuguese',
  'ro': 'Romanian',
  'ru': 'Russian',
  'sa': 'Sanskrit',
  'sd': 'Sindhi',
  'si': 'Sinhala',
  'sk': 'Slovak',
  'sl': 'Slovenian',
  'sn': 'Shona',
  'so': 'Somali',
  'sq': 'Albanian',
  'sr': 'Serbian',
  'su': 'Sundanese',
  'sv': 'Swedish',
  'sw': 'Swahili',
  'ta': 'Tamil',
  'te': 'Telugu',
  'tg': 'Tajik',
  'th': 'Thai',
  'tk': 'Turkmen',
  'tl': 'Tagalog',
  'tr': 'Turkish',
  'tt': 'Tatar',
  'uk': 'Ukrainian',
  'ur': 'Urdu',
  'uz': 'Uzbek',
  'vi': 'Vietnamese',
  'yi': 'Yiddish',
  'yo': 'Yoruba',
  'yue': 'Cantonese',
  'zh': 'Chinese',
  'zu': 'Zulu',
};

/// Language codes, in the order a person chose them.
abstract final class SpeechLanguages {
  /// English name for [code], or null when whisper does not know it.
  ///
  /// Dialect tags fold to their base (`en-GB` → `en`, `pt_BR` → `pt`).
  static String? nameOf(String code) => whisperLanguages[normalise(code)];

  /// [nameOf] with an honest fallback for a transcript that has no language:
  /// the raw code when it is unknown, `unknown` when it is empty.
  static String label(String code) {
    final name = nameOf(code);
    if (name != null) return name;
    final trimmed = code.trim();
    return trimmed.isEmpty ? 'unknown' : trimmed;
  }

  /// Lower-case base code: `EN-gb` → `en`.
  static String normalise(String code) {
    final cleaned = code.trim().toLowerCase().replaceAll('_', '-');
    final dash = cleaned.indexOf('-');
    return dash < 0 ? cleaned : cleaned.substring(0, dash);
  }

  /// Unknown codes and duplicates dropped, order kept.
  ///
  /// Called on every path that reads the setting — a preference written by an
  /// older build (or by hand) must not put an empty or invented language on the
  /// wire.
  static List<String> sanitise(Iterable<String?> codes) {
    final out = <String>[];
    for (final raw in codes) {
      if (raw == null) continue;
      final code = normalise(raw);
      if (code.isEmpty || !whisperLanguages.containsKey(code)) continue;
      if (!out.contains(code)) out.add(code);
    }
    return out;
  }

  /// What a backend should force on its only pass. Empty means "detect".
  ///
  /// One chosen language is worth forcing: whisper's detector is the part that
  /// gets short, noisy or code-switched takes wrong. More than one is not —
  /// whisper takes a single language, so the take is left to detection and
  /// [covers] decides afterwards whether that answer was acceptable.
  static String forceFor(List<String> languages) =>
      languages.length == 1 ? languages.first : '';

  /// Whether [detected] is one of [languages]. Empty [languages] covers
  /// everything (detection was the point), and an unknown detection covers
  /// nothing — that is when the fallback pass earns its cost.
  static bool covers(List<String> languages, String detected) {
    if (languages.isEmpty) return true;
    final d = normalise(detected);
    if (d.isEmpty) return false;
    if (languages.contains(d)) return true;
    // Some backends answer with the language's name rather than its code.
    final name = detected.trim().toLowerCase();
    return whisperLanguages.entries.any(
      (e) => languages.contains(e.key) && e.value.toLowerCase() == name,
    );
  }

  /// `auto`, or the chosen languages by name: `English, German`.
  static String describe(List<String> languages) {
    if (languages.isEmpty) return 'auto';
    return [for (final code in languages) nameOf(code) ?? code].join(', ');
  }
}
