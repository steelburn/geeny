import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/ai_client.dart';
import 'package:geeny_app/ai/ai_settings.dart';
import 'package:geeny_app/ai/ask.dart';
import 'package:geeny_app/ai/device/device_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the real on-device engine: records what was asked of it and
/// answers in the shapes the rest of the app expects.
class FakeDeviceAi extends DeviceAi {
  FakeDeviceAi(super.settings);

  int transcriptions = 0;
  final List<String> languages = [];
  final List<String> templates = [];
  final List<String> titles = [];

  @override
  Future<Map<String, dynamic>> transcribe(File audio,
      {List<String> languages = const []}) async {
    transcriptions++;
    this.languages
      ..clear()
      ..addAll(languages);
    return {
      'source': audio.path,
      'language': 'en',
      'duration': 4.0,
      'segments': [
        {'start': 0.0, 'end': 4.0, 'text': 'A sentence from the take.'},
      ],
      'engine': 'on device · whisper tiny',
    };
  }

  @override
  Future<Map<String, dynamic>> summarize(
    Map<String, dynamic> transcript, {
    required String template,
  }) async {
    templates.add(template);
    return {
      'template': template,
      'engine': 'extractive · on device',
      'sections': {
        'Overview': ['A sentence from the take.'],
      },
    };
  }

  /// Set to answer `answer()` with a cited line, or null to model "no model".
  String? answerText;

  @override
  Future<({String text, String engine})?> answer(
      String question, List<AskHit> hits) async {
    final text = answerText;
    if (text == null) return null;
    return (text: text, engine: 'on device · llama.cpp · fake');
  }

  @override
  Future<String?> title(Map<String, dynamic> transcript) async {
    titles.add('device title');
    return 'device title';
  }

  @override
  Future<String?> probe() async => null;

  @override
  Future<Map<String, dynamic>> health() async => {'ok': true, 'engine': 'on device'};
}

/// Stands in for the machine's service: the probe may find it or not, but its
/// model never gets to answer, which is the case a phone on its own hits.
class SilentMachineClient extends AiClient {
  SilentMachineClient(super.settings, {super.deviceOverride});

  @override
  Future<AskAnswer?> ask(String question, {int limit = 6}) async => null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a device backend is persisted as device, not as local', () async {
    final settings = AiSettings()
      ..setSpeechBackend(AiBackend.device)
      ..setSummaryBackend(AiBackend.device)
      ..setDeviceSpeech('base')
      ..setDeviceSummary('qwen2.5-0.5b-instruct-q4_k_m');
    await settings.save();

    final reloaded = AiSettings();
    await reloaded.load();

    expect(reloaded.speechBackend, AiBackend.device);
    expect(reloaded.speechOnDevice, isTrue);
    expect(reloaded.usesDevice, isTrue);
    expect(reloaded.usesLocal, isFalse);
    expect(reloaded.usesExternal, isFalse);
    expect(reloaded.deviceSpeech, 'base');
    expect(reloaded.deviceSummary, 'qwen2.5-0.5b-instruct-q4_k_m');
    expect(reloaded.speechLabel, 'on device · whisper base');
  });

  test('each half routes independently, and the label says so', () {
    final settings = AiSettings()
      ..speechBackend = AiBackend.device
      ..summaryBackend = AiBackend.local;
    expect(settings.usesDevice, isTrue);
    expect(settings.usesLocal, isTrue);
    expect(settings.routingLabel, 'device speech · machine summary');
    expect(settings.speechLabel, startsWith('on device'));
    expect(settings.summaryLabel, startsWith('on this machine'));
  });

  test('a mixed external + device setup probes only the halves in use', () {
    final settings = AiSettings()
      ..speechBackend = AiBackend.device
      ..summaryBackend = AiBackend.external;
    expect(settings.usesExternal, isTrue);
    expect(settings.routingLabel, 'device speech · external summary');
  });

  test('transcription and summaries go to the device when it is selected', () async {
    final settings = AiSettings()
      ..speechBackend = AiBackend.device
      ..summaryBackend = AiBackend.device;
    final device = FakeDeviceAi(settings);
    final client = AiClient(settings, deviceOverride: device);

    final transcript = await client.transcribe(File('/tmp/take.ogg'));
    expect(device.transcriptions, 1);
    expect(transcript['engine'], 'on device · whisper tiny');

    final summary = await client.summarize(transcript, template: 'lecture');
    expect(device.templates, ['lecture']);
    expect((summary['sections'] as Map)['Overview'], ['A sentence from the take.']);

    expect(await client.title(transcript), 'device title');
    expect(await client.probe(), isNull);
    expect(await client.deviceHealth(), isNotNull);
  });

  test('transcription sends the remembered languages to the device half', () async {
    final settings = AiSettings()
      ..speechBackend = AiBackend.device
      ..summaryBackend = AiBackend.device;
    final device = FakeDeviceAi(settings);
    final client = AiClient(settings, deviceOverride: device);

    await client.transcribe(File('/tmp/take.ogg'), languages: const ['DE', 'en-GB', 'de']);
    expect(device.languages, ['de', 'en']);

    // Nothing declared stays "detect": an empty list, not a guess.
    await client.transcribe(File('/tmp/take.ogg'));
    expect(device.languages, isEmpty);
  });

  test('the device is left alone when both halves are elsewhere', () async {
    final settings = AiSettings()
      ..speechBackend = AiBackend.local
      ..summaryBackend = AiBackend.external;
    final device = FakeDeviceAi(settings);
    final client = AiClient(settings, deviceOverride: device);

    expect(await client.deviceHealth(), isNull);
    expect(device.transcriptions, 0);
  });

  test('the last summary type is remembered, and only known ones', () async {
    final settings = AiSettings();
    await settings.load();
    // A fresh install starts on meeting, not on an empty summary.
    expect(settings.summaryTemplate, 'meeting');

    settings.setSummaryTemplate('lecture');
    await settings.save();
    final reloaded = AiSettings();
    await reloaded.load();
    expect(reloaded.summaryTemplate, 'lecture');

    // A hand-edited or retired template must not become an empty summary.
    reloaded.setSummaryTemplate('podcast');
    await reloaded.save();
    final again = AiSettings();
    await again.load();
    expect(again.summaryTemplate, 'lecture');
  });

  group('answering over retrieved passages', () {
    List<AskHit> hits() => [
          AskHit(id: '/takes/a.ogg', title: 'Sampling plan', text: 'Marta sends the schedule.', start: 12),
          AskHit(id: '/takes/a.ogg', title: 'Sampling plan', text: 'Budget is next month.', section: 'Overview'),
        ];

    test('the on-device model writes the answer and its citation is marked', () async {
      final settings = AiSettings()..summaryBackend = AiBackend.device;
      final device = FakeDeviceAi(settings)
        ..answerText = 'Marta sends the revised schedule. [1]';
      final client = AiClient(settings, deviceOverride: device);

      final answer = await client.answer('who sends the schedule?', hits());
      expect(answer, isNotNull);
      expect(answer!.answer, contains('Marta'));
      expect(answer.engine, contains('on device'));
      expect(answer.sources.first.cited, isTrue);
      expect(answer.sources.last.cited, isFalse);
    });

    test('a machine with nothing to say hands over to the device model', () async {
      final settings = AiSettings()..summaryBackend = AiBackend.local;
      final device = FakeDeviceAi(settings)..answerText = 'From the phone. [2]';
      final client = SilentMachineClient(settings, deviceOverride: device);

      final answer = await client.answer('who sends the schedule?', hits());
      expect(answer, isNotNull);
      expect(answer!.engine, contains('on device'));
      expect(answer.sources.last.cited, isTrue);
      expect(answer.sources.first.cited, isFalse);
    });

    test('an unreachable external service falls back to the device model', () async {
      final settings = AiSettings()
        ..summaryBackend = AiBackend.external
        // `.invalid` is reserved: the lookup fails immediately, no timeout.
        ..externalUrl = 'http://geeny.invalid/v1';
      final device = FakeDeviceAi(settings)..answerText = 'Answered offline. [1]';
      final client = AiClient(settings, deviceOverride: device);

      final answer = await client.answer('who sends the schedule?', hits());
      expect(answer, isNotNull);
      expect(answer!.engine, contains('on device'));
    });

    test('an external service that answers with an error is not hidden', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.statusCode = 401;
        request.response.write('{"error": "bad key"}');
        request.response.close();
      });

      final settings = AiSettings()
        ..summaryBackend = AiBackend.external
        ..externalUrl = 'http://127.0.0.1:${server.port}/v1';
      final device = FakeDeviceAi(settings)..answerText = 'Should not be used. [1]';
      final client = AiClient(settings, deviceOverride: device);

      await expectLater(client.answer('anything', hits()), throwsA(isA<Exception>()));
    });

    test('a model that produces nothing is null, so the passages stand in', () async {
      final settings = AiSettings()..summaryBackend = AiBackend.device;
      final device = FakeDeviceAi(settings)..answerText = null;
      final client = AiClient(settings, deviceOverride: device);

      expect(await client.answer('anything', hits()), isNull);
      expect(await client.answer('anything', const []), isNull);
    });
  });

  test('an unconfigured device summary reads as extractive, not as a model name', () {
    final settings = AiSettings()
      ..summaryBackend = AiBackend.device
      ..deviceSummary = 'extractive';
    expect(settings.summaryLabel, 'on device · extractive');
  });
}
