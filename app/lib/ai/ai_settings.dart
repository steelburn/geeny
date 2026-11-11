import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where a single job (speech-to-text or summarising) runs.
enum AiBackend {
  /// `scripts/ai_server.py` on your own machine (whisper + a local GGUF).
  local,

  /// An OpenAI-compatible endpoint (OpenAI, Groq, a LAN llama.cpp, LM Studio…).
  /// Audio/transcripts go to that service, so it is a deliberate opt-in.
  external,
}

/// Persisted AI configuration. Speech and summary are configured **separately**,
/// so local speech + an external summary model (or the reverse) is a valid setup.
///
/// The local service address is not a user setting: the app owns it. It uses the
/// built-in default, overridable at build time with
/// `--dart-define=NOTRA_AI_URL=http://192.168.1.20:8765`, and probes the usual
/// suspects on first use (see [localUrlCandidates]).
///
/// Personal tool: the API key lives in app preferences, not a system keystore.
class AiSettings extends ChangeNotifier {
  AiSettings();

  static const _kSpeechBackend = 'ai.speechBackend';
  static const _kSummaryBackend = 'ai.summaryBackend';
  static const _kLegacyMode = 'ai.mode';
  static const _kLocalUrl = 'ai.localUrl';
  static const _kLocalSpeech = 'ai.localSpeech';
  static const _kLocalSummary = 'ai.localSummary';
  static const _kExtUrl = 'ai.externalUrl';
  static const _kExtKey = 'ai.externalKey';
  static const _kExtSpeech = 'ai.externalSpeech';
  static const _kExtSummary = 'ai.externalSummary';

  /// Compile-time default for the on-this-machine service.
  static const defaultLocalUrl = String.fromEnvironment(
    'NOTRA_AI_URL',
    defaultValue: 'http://127.0.0.1:8765',
  );

  /// Probed in order until one answers `/health`. The app remembers the winner,
  /// so a LAN address discovered once does not have to be typed in again.
  static const localUrlCandidates = <String>[
    defaultLocalUrl,
    'http://127.0.0.1:8765',
    'http://localhost:8765',
    'http://10.0.2.2:8765', // Android emulator's host loopback
  ];

  static const whisperModels = ['tiny', 'base', 'small', 'medium'];

  AiBackend speechBackend = AiBackend.local;
  AiBackend summaryBackend = AiBackend.local;

  // --- on this machine -------------------------------------------------------
  /// Resolved by the app (default, build-time override, or discovery).
  String localUrl = defaultLocalUrl;
  String localSpeech = 'small';

  /// GGUF stem, or `auto` to let the service pick its default, or `extractive`.
  String localSummary = 'auto';

  // --- external service ------------------------------------------------------
  String externalUrl = 'https://api.openai.com/v1';
  String externalKey = '';
  String externalSpeech = 'whisper-1';
  String externalSummary = 'gpt-4o-mini';

  bool get speechExternal => speechBackend == AiBackend.external;
  bool get summaryExternal => summaryBackend == AiBackend.external;
  bool get usesLocal => !speechExternal || !summaryExternal;
  bool get usesExternal => speechExternal || summaryExternal;

  /// Short label for the speech half of the pipeline.
  String get speechLabel =>
      speechExternal ? 'external · $externalSpeech' : 'local · whisper $localSpeech';

  /// Short label for the summary half of the pipeline.
  String get summaryLabel => summaryExternal
      ? 'external · $externalSummary'
      : 'local · ${localSummary == 'auto' ? 'default summary' : shortModelName(localSummary)}';

  /// GGUF stems are long (`qwen2.5-1.5b-instruct-q4_k_m`); the UI only needs the
  /// part that tells two models apart.
  static String shortModelName(String name) {
    var n = name
        .replaceAll(RegExp(r'-?q4_k_m', caseSensitive: false), '')
        .replaceAll('-instruct', '')
        .replaceAll('.gguf', '');
    n = n.replaceAll(RegExp(r'-+$'), '');
    return n.isEmpty ? name : n;
  }

  /// One line for the Setup disclosure: routing without the model names.
  String get routingLabel => speechExternal || summaryExternal
      ? '${speechExternal ? 'external' : 'local'} speech · '
          '${summaryExternal ? 'external' : 'local'} summary'
      : 'on this device';

  static AiBackend? _parseBackend(String? value) => switch (value) {
        'external' => AiBackend.external,
        'local' => AiBackend.local,
        _ => null,
      };

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();

    // Older builds had one mode for both jobs; use it as the starting point.
    final legacy = _parseBackend(p.getString(_kLegacyMode)) ?? AiBackend.local;
    speechBackend = _parseBackend(p.getString(_kSpeechBackend)) ?? legacy;
    summaryBackend = _parseBackend(p.getString(_kSummaryBackend)) ?? legacy;

    localUrl = p.getString(_kLocalUrl) ?? localUrl;
    localSpeech = p.getString(_kLocalSpeech) ?? localSpeech;
    localSummary = p.getString(_kLocalSummary) ?? localSummary;
    externalUrl = p.getString(_kExtUrl) ?? externalUrl;
    externalKey = p.getString(_kExtKey) ?? externalKey;
    externalSpeech = p.getString(_kExtSpeech) ?? externalSpeech;
    externalSummary = p.getString(_kExtSummary) ?? externalSummary;
    notifyListeners();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSpeechBackend, speechExternal ? 'external' : 'local');
    await p.setString(_kSummaryBackend, summaryExternal ? 'external' : 'local');
    await p.setString(_kLocalUrl, localUrl);
    await p.setString(_kLocalSpeech, localSpeech);
    await p.setString(_kLocalSummary, localSummary);
    await p.setString(_kExtUrl, externalUrl);
    await p.setString(_kExtKey, externalKey);
    await p.setString(_kExtSpeech, externalSpeech);
    await p.setString(_kExtSummary, externalSummary);
    notifyListeners();
  }

  /// Called by [AiClient] when discovery finds the service at another address.
  Future<void> setLocalUrl(String url) async {
    if (url == localUrl) return;
    localUrl = url;
    await save();
  }

  void setSpeechBackend(AiBackend b) {
    speechBackend = b;
    save();
  }

  void setSummaryBackend(AiBackend b) {
    summaryBackend = b;
    save();
  }

  void setLocalSpeech(String m) {
    localSpeech = m;
    save();
  }

  void setLocalSummary(String m) {
    localSummary = m;
    save();
  }
}
