import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import '../ai_settings.dart';
import '../ask.dart';
import '../notes.dart';
import 'audio_io.dart';
import 'device_asr.dart';
import 'device_llm.dart';
import 'device_models.dart';
import 'extractive.dart';

/// The on-device pipeline: audio → whisper → transcript → GGUF → summary.
///
/// Both halves run on the phone itself with no service and no network, so this
/// is the one backend that works on a train. Models are downloaded once (the
/// picker in Settings does it), kept in the app's support directory, and never
/// uploaded anywhere.
///
/// Heavy work is handed to a short-lived isolate per job. That is deliberate:
/// whisper and llama.cpp are CPU-bound FFI, the UI isolate must stay responsive,
/// and exiting the isolate is also what gives the memory back — several hundred
/// megabytes matter on a phone.
class DeviceAi {
  DeviceAi(this.settings);

  final AiSettings settings;

  DeviceModels? _models;

  /// Null until [models] has resolved the support directory (first use).
  DeviceModels? get modelsIfReady => _models;

  /// Resolve the model store, creating its directory on first use.
  Future<DeviceModels> models() async {
    final cached = _models;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final store = DeviceModels(Directory('${support.path}/models'));
    await store.init();
    return _models = store;
  }

  // --- model choice ---------------------------------------------------------

  DeviceModel? get speechModel {
    for (final m in deviceSpeechModels) {
      if (m.label == settings.deviceSpeech) return m;
    }
    return deviceSpeechModels.first;
  }

  /// The configured summary model, or null when the setting means "whichever is
  /// installed" / "extractive".
  DeviceModel? get summaryModel {
    final wanted = settings.deviceSummary;
    if (wanted == 'auto' || wanted == 'extractive') return null;
    return DeviceModels.byName(wanted);
  }

  /// The GGUF a summary will actually use: the chosen one when it is installed,
  /// the first installed one for `auto`, and null whenever the honest answer is
  /// the extractive fallback (explicitly chosen, or the chosen model is gone).
  Future<DeviceModel?> summaryModelInUse() async {
    final wanted = settings.deviceSummary;
    if (wanted == 'extractive') return null;

    final store = await models();
    final chosen = summaryModel;
    if (chosen != null) return store.isInstalled(chosen) ? chosen : null;

    final installed = store.installed(ModelKind.summary);
    return installed.isEmpty ? null : installed.first;
  }

  // --- jobs -----------------------------------------------------------------

  Future<Map<String, dynamic>> transcribe(File audio,
      {List<String> languages = const []}) async {
    final store = await models();
    final model = speechModel!;
    if (!store.isInstalled(model)) {
      throw Exception('whisper ${model.label} is not on this device yet — download it '
          'in Setup, under Speech → On this device');
    }

    final temp = await getTemporaryDirectory();
    final work = Directory('${temp.path}/geeny-${DateTime.now().microsecondsSinceEpoch}');
    try {
      final wav = await DeviceAudio.decodeToPcm(audio, work);
      // Only plain values cross into the worker isolate.
      final wavPath = wav.path;
      final bundleDir = model.pathIn(store.root.path);
      final source = audio.path;
      final label = model.label;
      final threads = Platform.numberOfProcessors >= 6 ? 4 : 2;
      return await _transcribeInIsolate(
        wavPath: wavPath,
        bundleDir: bundleDir,
        source: source,
        label: label,
        threads: threads,
        languages: languages,
      );
    } finally {
      // As much for privacy as for space: the decoded copy is the whole take.
      try {
        if (work.existsSync()) await work.delete(recursive: true);
      } catch (_) {
        // Leftover temp files are the OS's to clean.
      }
    }
  }

  Future<Map<String, dynamic>> summarize(
    Map<String, dynamic> transcript, {
    required String template,
  }) async {
    final text = _textOf(transcript);
    if (text.isEmpty) throw Exception('the transcript is empty');

    final store = await models();
    final model = await summaryModelInUse();
    if (model != null) {
      final ggufPath = model.pathIn(store.root.path);
      final label = model.label;
      final language = (transcript['language'] ?? '').toString();
      final result = await _summarizeInIsolate(
        ggufPath: ggufPath,
        transcriptText: text,
        template: template,
        label: label,
        language: language,
      );
      if (result != null) return result;
      // A model that cannot answer is not an error: fall through to the
      // extractive summary rather than failing the take.
    }
    return extractiveSummary(transcript, template);
  }

  /// A short title, from the GGUF when one is installed, else the opening words.
  Future<String?> title(Map<String, dynamic> transcript) async {
    final text = _textOf(transcript);
    if (text.isEmpty) return null;

    final store = await models();
    final model = await summaryModelInUse();
    if (model != null) {
      final ggufPath = model.pathIn(store.root.path);
      final title = await _titleInIsolate(ggufPath: ggufPath, transcriptText: text);
      final clean = cleanTitle(title);
      if (clean != null) return clean;
    }
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return null;
    final lead = words.take(7).join(' ').replaceAll(RegExp(r'[\s.,:;-]+$'), '');
    return cleanTitle(words.length > 7 ? '$lead…' : lead);
  }

  // --- status ---------------------------------------------------------------

  /// `null` when the on-device halves are usable, else what to fix.
  Future<String?> probe() async {
    final store = await models();
    final problems = <String>[];
    if (settings.speechOnDevice) {
      final model = speechModel!;
      if (!store.isInstalled(model)) {
        problems.add('Speech: whisper ${model.label} (${DeviceModel.sizeLabel(model.bytes)}) '
            'is not downloaded');
      }
    }
    if (settings.summaryOnDevice) {
      final chosen = summaryModel;
      if (chosen != null && !store.isInstalled(chosen)) {
        problems.add('Summary: ${chosen.label} (${DeviceModel.sizeLabel(chosen.bytes)}) '
            'is not downloaded');
      }
    }
    return problems.isEmpty ? null : problems.join(' · ');
  }

  /// What the panel needs to draw the on-device pickers.
  Future<Map<String, dynamic>> health() async {
    final store = await models();
    Map<String, dynamic> describe(DeviceModel m) => {
          'id': m.id,
          'label': m.label,
          'detail': m.detail,
          'bytes': m.bytes,
          'installed': store.isInstalled(m),
          'on_disk': store.installedBytes(m),
        };
    return {
      'ok': true,
      'engine': 'on device',
      'speech': [for (final m in deviceSpeechModels) describe(m)],
      'summary': [for (final m in deviceSummaryModels) describe(m)],
      'installed_summary': [for (final m in store.installed(ModelKind.summary)) m.id],
      'total_bytes': store.totalBytes,
      'in_use': (await summaryModelInUse())?.id,
    };
  }

  /// A written answer over [hits], from the on-device GGUF. Null when no summary
  /// model is installed, or when the model produced nothing usable — the caller
  /// then shows the passages themselves rather than an empty sheet.
  Future<({String text, String engine})?> answer(
      String question, List<AskHit> hits) async {
    if (hits.isEmpty) return null;
    final store = await models();
    final model = await summaryModelInUse();
    if (model == null) return null;
    final excerpts = [
      for (var i = 0; i < hits.length; i++) hits[i].excerpt(i + 1),
    ].join('\n');
    final text = await _answerInIsolate(
      ggufPath: model.pathIn(store.root.path),
      question: question,
      excerpts: excerpts,
    );
    if (text == null) return null;
    return (text: text, engine: 'on device · llama.cpp · ${model.label}');
  }

  static String _textOf(Map<String, dynamic> transcript) => [
        for (final s in (transcript['segments'] as List? ?? const []))
          if (s is Map) (s['text'] ?? '').toString(),
      ].join(' ').trim();

  // The worker closures are built in static methods, never in an instance
  // method: a closure made inside an instance method captures `this`, and this
  // object holds the settings (a ChangeNotifier) and the model store, neither of
  // which can cross an isolate boundary.
  static Future<Map<String, dynamic>> _transcribeInIsolate({
    required String wavPath,
    required String bundleDir,
    required String source,
    required String label,
    required int threads,
    required List<String> languages,
  }) =>
      Isolate.run(() => transcribeWav(
            wavPath: wavPath,
            bundleDir: bundleDir,
            source: source,
            modelLabel: label,
            threads: threads,
            languages: languages,
          ));

  static Future<Map<String, dynamic>?> _summarizeInIsolate({
    required String ggufPath,
    required String transcriptText,
    required String template,
    required String label,
    required String language,
  }) =>
      Isolate.run(() => summarizeWithGguf(
            ggufPath: ggufPath,
            transcriptText: transcriptText,
            template: template,
            modelLabel: label,
            language: language,
          ));

  static Future<String?> _titleInIsolate({
    required String ggufPath,
    required String transcriptText,
  }) =>
      Isolate.run(() => titleWithGguf(
            ggufPath: ggufPath,
            transcriptText: transcriptText,
          ));

  static Future<String?> _answerInIsolate({
    required String ggufPath,
    required String question,
    required String excerpts,
  }) =>
      Isolate.run(() => answerWithGguf(
            ggufPath: ggufPath,
            question: question,
            excerpts: excerpts,
          ));
}
