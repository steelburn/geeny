import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'languages.dart';
import 'notes.dart';

/// Where a single job (speech-to-text or summarising) runs.
enum AiBackend {
  /// On this phone/tablet: whisper and a GGUF loaded into the app's own process
  /// by `lib/ai/device/`. No service, no network, nothing metered — slower than a
  /// PC and with a smaller summary model.
  device,

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
  static const _kDeviceSpeech = 'ai.deviceSpeech';
  static const _kDeviceSummary = 'ai.deviceSummary';
  static const _kLegacyMode = 'ai.mode';
  static const _kLocalUrl = 'ai.localUrl';
  static const _kLocalSpeech = 'ai.localSpeech';
  static const _kLocalSummary = 'ai.localSummary';
  static const _kExtUrl = 'ai.externalUrl';
  static const _kExtKey = 'ai.externalKey';
  static const _kExtSpeech = 'ai.externalSpeech';
  static const _kExtSummary = 'ai.externalSummary';
  static const _kSummaryTemplate = 'ai.summaryTemplate';
  static const _kSpeechLanguages = 'ai.speechLanguages';

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

  // --- on this device --------------------------------------------------------
  /// whisper size label: `tiny` / `base` / `small`.
  String deviceSpeech = 'tiny';

  /// `auto` (the first installed GGUF, else extractive), `extractive`, or the id
  /// of a downloaded GGUF.
  String deviceSummary = 'extractive';

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

  /// The summary type last chosen for a take (`meeting` / `lecture` / `plain`).
  ///
  /// A new take opens the notes sheet on this instead of asking from a default
  /// every time; a take that already has notes keeps its own template.
  String summaryTemplate = 'meeting';

  /// Whisper codes the recorder's audio may contain, in choice order; empty
  /// means "let whisper detect".
  ///
  /// A meeting can mix two languages, so this is a list rather than one value.
  /// It is asked for before the first transcription and remembered across
  /// sessions, because the languages a person records in rarely change take to
  /// take. See [SpeechLanguages] for what the backends do with it.
  List<String> speechLanguages = const [];

  bool get speechExternal => speechBackend == AiBackend.external;
  bool get summaryExternal => summaryBackend == AiBackend.external;
  bool get speechOnDevice => speechBackend == AiBackend.device;
  bool get summaryOnDevice => summaryBackend == AiBackend.device;
  bool get usesDevice => speechOnDevice || summaryOnDevice;
  bool get usesLocal => speechBackend == AiBackend.local || summaryBackend == AiBackend.local;
  bool get usesExternal => speechExternal || summaryExternal;

  /// Short label for the speech half of the pipeline.
  String get speechLabel => switch (speechBackend) {
        AiBackend.device => 'on device · whisper $deviceSpeech',
        AiBackend.external => 'external · $externalSpeech',
        AiBackend.local => 'on this machine · whisper $localSpeech',
      };

  /// Short label for the summary half of the pipeline.
  String get summaryLabel => switch (summaryBackend) {
        AiBackend.device => 'on device · ${deviceSummary == 'auto' ? 'best installed summary' : deviceSummary == 'extractive' ? 'extractive' : shortModelName(deviceSummary)}',
        AiBackend.external => 'external · $externalSummary',
        AiBackend.local => 'on this machine · ${localSummary == 'auto' ? 'default summary' : shortModelName(localSummary)}',
      };

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

  /// `auto`, or the chosen languages by name, for a status line.
  String get speechLanguagesLabel => SpeechLanguages.describe(speechLanguages);

  /// One line for the Setup disclosure: routing without the model names.
  String get routingLabel {
    if (!usesDevice && !usesExternal) return 'on this machine';
    String half(AiBackend b) => switch (b) {
          AiBackend.device => 'device',
          AiBackend.local => 'machine',
          AiBackend.external => 'external',
        };
    return '${half(speechBackend)} speech · ${half(summaryBackend)} summary';
  }

  static AiBackend? _parseBackend(String? value) => switch (value) {
        'device' => AiBackend.device,
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
    deviceSpeech = p.getString(_kDeviceSpeech) ?? deviceSpeech;
    deviceSummary = p.getString(_kDeviceSummary) ?? deviceSummary;
    externalUrl = p.getString(_kExtUrl) ?? externalUrl;
    externalKey = p.getString(_kExtKey) ?? externalKey;
    externalSpeech = p.getString(_kExtSpeech) ?? externalSpeech;
    externalSummary = p.getString(_kExtSummary) ?? externalSummary;
    summaryTemplate = _parseTemplate(p.getString(_kSummaryTemplate));
    speechLanguages = SpeechLanguages.sanitise(p.getStringList(_kSpeechLanguages) ?? const []);
    notifyListeners();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSpeechBackend, _encode(speechBackend));
    await p.setString(_kSummaryBackend, _encode(summaryBackend));
    await p.setString(_kLocalUrl, localUrl);
    await p.setString(_kLocalSpeech, localSpeech);
    await p.setString(_kLocalSummary, localSummary);
    await p.setString(_kDeviceSpeech, deviceSpeech);
    await p.setString(_kDeviceSummary, deviceSummary);
    await p.setString(_kExtUrl, externalUrl);
    await p.setString(_kExtKey, externalKey);
    await p.setString(_kExtSpeech, externalSpeech);
    await p.setString(_kExtSummary, externalSummary);
    await p.setString(_kSummaryTemplate, summaryTemplate);
    await p.setStringList(_kSpeechLanguages, speechLanguages);
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

  static String _encode(AiBackend b) => switch (b) {
        AiBackend.device => 'device',
        AiBackend.local => 'local',
        AiBackend.external => 'external',
      };

  /// A stored template is only trusted if this build still knows it; an old or
  /// hand-edited preference falls back to the default instead of producing an
  /// empty summary.
  static String _parseTemplate(String? value) =>
      value != null && summaryTemplates.containsKey(value) ? value : 'meeting';

  void setSummaryTemplate(String template) {
    if (!summaryTemplates.containsKey(template) || template == summaryTemplate) return;
    summaryTemplate = template;
    save();
  }

  /// Replace the language list. Unknown codes are dropped and the order is
  /// kept: the first language is the one used as a fallback (see
  /// [SpeechLanguages.forceFor]).
  void setSpeechLanguages(Iterable<String> codes) {
    final next = SpeechLanguages.sanitise(codes);
    if (listEquals(next, speechLanguages)) return;
    speechLanguages = next;
    save();
  }

  void setDeviceSpeech(String size) {
    deviceSpeech = size;
    save();
  }

  void setDeviceSummary(String model) {
    deviceSummary = model;
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
