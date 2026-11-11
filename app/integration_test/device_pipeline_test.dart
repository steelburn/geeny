import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/ai_settings.dart';
import 'package:geeny_app/ai/device/device_ai.dart';
import 'package:geeny_app/ai/device/device_models.dart';
import 'package:geeny_app/ai/notes.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// End-to-end on a real phone or tablet: Ogg Opus → platform decode → whisper →
/// transcript → llama.cpp → summary. Nothing here talks to the AI service, so a
/// pass means the offline path genuinely works.
///
/// Media is served from the development machine over `adb reverse` (the same
/// trick the app uses for the service), which keeps the test reproducible and
/// independent of the tablet's own network:
///
///   mkdir -p /tmp/geeny-test && cd /tmp/geeny-test
///   curl -LO https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.tar.bz2
///   curl -L -o qwen2.5-0.5b-instruct-q4_k_m.gguf \
///     https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
///   uv run --with soundfile --with numpy python scripts/make_test_clip.py take-test.ogg
///   python -m http.server 8899 --directory /tmp/geeny-test &
///   adb reverse tcp:8899 tcp:8899
///   flutter test integration_test/device_pipeline_test.dart -d DEVICE_ID
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const base = String.fromEnvironment('TEST_MEDIA', defaultValue: 'http://127.0.0.1:8899');

  testWidgets('an Ogg Opus take is transcribed and summarised on this device',
      (tester) async {
    final support = await getApplicationSupportDirectory();
    final store = DeviceModels(Directory('${support.path}/models'));
    await store.init();

    // The catalog entry, but pointed at the development machine. The ids and
    // required files are the real ones, so this exercises the real install
    // layout, download and unpack path.
    const speech = DeviceModel(
      id: 'whisper-tiny',
      kind: ModelKind.speech,
      label: 'tiny',
      bytes: 116204861,
      url: '$base/sherpa-onnx-whisper-tiny.tar.bz2',
    );
    const summaryModel = DeviceModel(
      id: 'qwen2.5-0.5b-instruct-q4_k_m',
      kind: ModelKind.summary,
      label: '0.5B',
      bytes: 491400032,
      url: '$base/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    );

    if (!store.isInstalled(speech)) {
      await store.download(speech);
    }
    expect(store.isInstalled(speech), isTrue,
        reason: 'whisper tiny did not install: ${store.progressOf(speech)?.error}');
    if (!store.isInstalled(summaryModel)) {
      await store.download(summaryModel);
    }
    expect(store.isInstalled(summaryModel), isTrue,
        reason: 'the GGUF did not install: ${store.progressOf(summaryModel)?.error}');
    debugPrint('models on device: ${DeviceModel.sizeLabel(store.totalBytes)}');

    // A 17 s Ogg Opus, mono, 16 kHz — the recorder's own format.
    final clip = File('${support.path}/take-test.ogg');
    if (!clip.existsSync()) {
      final response = await http.get(Uri.parse('$base/take-test.ogg'));
      expect(response.statusCode, 200, reason: 'is the media server running?');
      await clip.writeAsBytes(response.bodyBytes);
    }
    expect(clip.lengthSync(), greaterThan(1000));

    final settings = AiSettings()
      ..speechBackend = AiBackend.device
      ..summaryBackend = AiBackend.device
      ..deviceSpeech = 'tiny'
      ..deviceSummary = summaryModel.id;
    final ai = DeviceAi(settings);

    expect(await ai.probe(), isNull);

    // --- speech -------------------------------------------------------------
    final stopwatch = Stopwatch()..start();
    final transcript = await ai.transcribe(clip);
    stopwatch.stop();
    debugPrint('transcription: ${stopwatch.elapsedMilliseconds} ms');

    final segments = (transcript['segments'] as List).cast<Map<String, dynamic>>();
    expect(segments, isNotEmpty, reason: 'whisper returned no segments');
    final text = segments.map((s) => s['text']).join(' ').toLowerCase();
    debugPrint('transcript: $text');
    expect(text, contains('sampling'),
        reason: 'the clip says "we reviewed the sampling plan"');
    expect(transcript['engine'], 'on device · whisper tiny');
    expect((transcript['duration'] as num).toDouble(), closeTo(17, 2));

    var previous = -1.0;
    for (final segment in segments) {
      final start = (segment['start'] as num).toDouble();
      final end = (segment['end'] as num).toDouble();
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThanOrEqualTo(start));
      expect(start, greaterThanOrEqualTo(previous));
      previous = start;
    }

    // --- summary with a GGUF ------------------------------------------------
    final timer = Stopwatch()..start();
    final summary = await ai.summarize(transcript, template: 'meeting');
    timer.stop();
    debugPrint('summary (${summary['engine']}): ${timer.elapsedMilliseconds} ms');

    expect(summary['engine'].toString(), startsWith('on device · llama.cpp'),
        reason: 'the GGUF should have been used, not the fallback');
    final sections = summary['sections'] as Map<String, dynamic>;
    debugPrint('sections: $sections');
    expect(sections.keys.toList(), summaryTemplates['meeting']);
    final bullets = sections.values.expand((v) => v as List).toList();
    expect(bullets.length, greaterThanOrEqualTo(2),
        reason: 'a summary with no bullets is not a summary');
    expect((sections['Overview'] as List), isNotEmpty);

    // --- extractive, still entirely on device -------------------------------
    settings.deviceSummary = 'extractive';
    final extractive = await ai.summarize(transcript, template: 'meeting');
    expect(extractive['engine'], 'extractive · on device');
    expect((extractive['sections'] as Map).keys.toList(), summaryTemplates['meeting']);
    settings.deviceSummary = summaryModel.id;

    // --- titles come from the same model ------------------------------------
    final title = await ai.title(transcript);
    debugPrint('title: $title');
    expect(title, isNotNull);
    expect(title!.length, greaterThan(2));
  }, timeout: const Timeout(Duration(minutes: 15)));
}
