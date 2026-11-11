import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../languages.dart';
import 'audio_io.dart';
import 'segments.dart';

/// whisper on the device, through sherpa-onnx.
///
/// This runs inside its own isolate (see `device_ai.dart`): the model is loaded,
/// the take is decoded, one result is returned, and the isolate exits, which is
/// also what reclaims the several hundred megabytes a whisper session holds.
/// Every isolate needs its own `initBindings()` — sherpa-onnx is explicit about
/// that — so it is the first thing this function does.
///
/// The returned map is the same shape `scripts/ai_server.py` returns, so
/// everything downstream (sidecars, search, the notes sheet) cannot tell which
/// half of the pipeline produced it.
///
/// [languages] are whisper codes the take may contain, most likely first (see
/// [SpeechLanguages]). One code is forced on the only pass. Several leave the
/// first pass to whisper's own detector — the language can change mid-take —
/// and only when that guess lands outside the list is the first choice forced
/// with a second pass, which costs a second decode.
Map<String, dynamic> transcribeWav({
  required String wavPath,
  required String bundleDir,
  required String source,
  required String modelLabel,
  int threads = 0,
  List<String> languages = const [],
}) {
  sherpa.initBindings();

  final wave = DeviceAudio.parseWav(File(wavPath).readAsBytesSync());
  final duration = wave.length / DeviceAudio.sampleRate;
  final chosen = SpeechLanguages.sanitise(languages);

  var attempt = _attempt(
    wave,
    bundleDir: bundleDir,
    modelLabel: modelLabel,
    threads: threads,
    language: SpeechLanguages.forceFor(chosen),
  );
  if (chosen.length > 1 && !SpeechLanguages.covers(chosen, attempt.language)) {
    attempt = _attempt(
      wave,
      bundleDir: bundleDir,
      modelLabel: modelLabel,
      threads: threads,
      language: chosen.first,
    );
  }

  return {
    'source': source,
    'language': attempt.language.isEmpty ? '' : attempt.language,
    'duration': duration,
    'segments': attempt.segments,
    'engine': 'on device · whisper $modelLabel',
  };
}

/// One whisper pass. A language is a property of the model config, not the
/// stream, so a second pass needs its own recogniser — the reason several
/// languages cost a reload rather than a cheaper re-decode.
({String language, List<Map<String, dynamic>> segments}) _attempt(
  Float32List wave, {
  required String bundleDir,
  required String modelLabel,
  required int threads,
  required String language,
}) {
  final duration = wave.length / DeviceAudio.sampleRate;
  final model = sherpa.OfflineModelConfig(
    whisper: sherpa.OfflineWhisperModelConfig(
      encoder: '$bundleDir/encoder.int8.onnx',
      decoder: '$bundleDir/decoder.int8.onnx',
      language: language,
      enableTokenTimestamps: true,
    ),
    tokens: '$bundleDir/tokens.txt',
    modelType: 'whisper',
    numThreads: threads > 0 ? threads : _defaultThreads(),
    debug: false,
    provider: 'cpu',
  );

  final recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(model: model));
  final stream = recognizer.createStream();
  try {
    stream.acceptWaveform(samples: wave, sampleRate: DeviceAudio.sampleRate);
    recognizer.decode(stream);
    final result = recognizer.getResult(stream);
    final detected = result.lang.trim();
    return (
      // A forced language may come back as an empty `lang`; the take's language
      // is then the one that was forced, not "unknown".
      language: detected.isEmpty ? language : detected,
      segments: buildSegments(
        tokens: result.tokens,
        timestamps: result.timestamps,
        text: result.text,
        duration: duration,
      ),
    );
  } finally {
    stream.free();
    recognizer.free();
  }
}

/// Two threads leave the UI smooth-ish on a phone; more only helps on a tablet,
/// where the caller raises it.
int _defaultThreads() {
  final cores = Platform.numberOfProcessors;
  if (cores <= 2) return 1;
  if (cores <= 4) return 2;
  return 4;
}
