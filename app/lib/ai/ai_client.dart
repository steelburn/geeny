import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';
import 'ask.dart';
import 'device/device_ai.dart';
import 'device/device_models.dart';
import 'languages.dart';
import 'notes.dart';

/// Client for transcription/summaries.
///
/// Three backends, chosen independently for each job in [AiSettings]:
///  * device  — whisper + a GGUF inside the app (see [DeviceAi])
///  * local   — `scripts/ai_server.py` (whisper + a local GGUF, or extractive)
///  * external — any OpenAI-compatible API (`/audio/transcriptions` +
///    `/chat/completions`).
///
/// Search is answered by the device's model or by a connected service, whichever
/// is there — see [answer].
///
/// So on-device speech can feed the machine's summary model, and the other way
/// round. Nothing here uploads unless the half in question is External.
class AiClient {
  /// [deviceOverride] exists for tests: the real engine is built from [settings]
  /// and would otherwise need a phone to stand up.
  AiClient(this.settings, {DeviceAi? deviceOverride})
      : device = deviceOverride ?? DeviceAi(settings);

  final AiSettings settings;

  /// The on-device engine, its model store and its download progress.
  final DeviceAi device;

  Uri _local(String path, [Map<String, String>? query]) =>
      Uri.parse('${settings.localUrl}$path').replace(queryParameters: query);

  Uri _external(String path) {
    final base = settings.externalUrl.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  Map<String, String> get _auth => settings.externalKey.isEmpty
      ? const {}
      : {'Authorization': 'Bearer ${settings.externalKey}'};

  /// Addresses to try, current first, then the built-in candidates.
  Iterable<String> get _localCandidates sync* {
    final seen = <String>{};
    final base = settings.localUrl.replaceAll(RegExp(r'/+$'), '');
    if (seen.add(base)) yield base;
    for (final c in AiSettings.localUrlCandidates) {
      if (seen.add(c)) yield c;
    }
  }

  /// null when every selected backend looks usable, else a human-readable reason.
  Future<String?> probe({Duration timeout = const Duration(seconds: 6)}) async {
    final problems = <String>[];
    if (settings.usesDevice) {
      final p = await device.probe();
      if (p != null) problems.add(p);
    }
    if (settings.usesLocal) {
      final p = await _probeLocal();
      if (p != null) problems.add(p);
    }
    if (settings.usesExternal) {
      final p = await _probeExternal(timeout);
      if (p != null) problems.add(p);
    }
    return problems.isEmpty ? null : problems.join(' · ');
  }

  /// Installed on-device models, sizes and what is in use. Null when neither
  /// half is set to On this device.
  Future<Map<String, dynamic>?> deviceHealth() async {
    if (!settings.usesDevice) return null;
    return device.health();
  }

  /// The on-device model store, once its directory has been resolved.
  DeviceModels? get deviceModels => device.modelsIfReady;

  Future<DeviceModels> ensureDeviceModels() => device.models();

  /// Try the configured address and the usual suspects; adopt the one that answers.
  Future<String?> _probeLocal() async {
    final tried = <String>[];
    for (final base in _localCandidates) {
      tried.add(base);
      try {
        final r = await http
            .get(Uri.parse('$base/health'))
            .timeout(const Duration(milliseconds: 1500));
        if (r.statusCode != 200) continue;
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        if (body['ok'] != true) continue;
        await settings.setLocalUrl(base);
        return null;
      } catch (_) {
        // try the next address
      }
    }
    return 'No AI service found (${tried.join(', ')}) — start scripts/ai_server.py, or set '
        'Speech to On this device for offline whisper';
  }

  Future<String?> _probeExternal(Duration timeout) async {
    try {
      final r = await http.get(_external('/models'), headers: _auth).timeout(timeout);
      if (r.statusCode == 401) return 'External service rejected the API key';
      if (r.statusCode >= 400) return 'External service returned ${r.statusCode}';
      return null;
    } on SocketException {
      return 'Cannot reach ${settings.externalUrl}';
    } catch (e) {
      return 'External service unreachable: $e';
    }
  }

  /// Local service capabilities: whisper sizes, available GGUFs, speakers flag.
  /// Null when the local service is not part of the pipeline.
  Future<Map<String, dynamic>?> health() async {
    if (!settings.usesLocal) return null;
    for (final base in _localCandidates) {
      try {
        final r = await http
            .get(Uri.parse('$base/health'))
            .timeout(const Duration(seconds: 3));
        if (r.statusCode != 200) continue;
        await settings.setLocalUrl(base);
        return jsonDecode(r.body) as Map<String, dynamic>;
      } catch (_) {
        // try the next address
      }
    }
    return null;
  }

  /// Ask the local service to fetch a summary model from its catalog. The
  /// download runs on the serving machine; poll [modelDownload] for progress.
  Future<Map<String, dynamic>?> startModelDownload(String name) async {
    try {
      final r = await http
          .post(_local('/models/download'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'name': name}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Progress of a catalog download: `state` is downloading / done / error.
  Future<Map<String, dynamic>?> modelDownload(String name) async {
    try {
      final r = await http
          .get(_local('/models/download', {'name': name}))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// What the downloaded models take on the serving machine.
  Future<Map<String, dynamic>?> modelStorage() async {
    try {
      final r = await http
          .get(_local('/models/storage'))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Remove one downloaded model (`summary`, `speech` or `partial`).
  ///
  /// A failure carries the service's own reason, because "could not delete"
  /// without one is useless when the file is held open.
  Future<({int freed, String? error})> deleteModel(String kind, String name) async {
    try {
      final r = await http
          .post(_local('/models/delete'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'kind': kind, 'name': name}))
          .timeout(const Duration(seconds: 30));
      final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return (freed: 0, error: (body['error'] ?? 'delete failed').toString());
      }
      return (freed: (body['freed'] as num?)?.toInt() ?? 0, error: null);
    } catch (e) {
      return (freed: 0, error: 'Could not reach the local service: $e');
    }
  }

  // --- search / ask ---------------------------------------------------------

  /// Push the library's transcripts and summaries to the local index.
  Future<Map<String, dynamic>?> indexDocuments(List<Map<String, dynamic>> documents) async {
    try {
      final r = await http
          .post(_local('/index'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'documents': documents}))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return null;
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// A written answer with citations, from the model on the machine.
  Future<AskAnswer?> ask(String question, {int limit = 6}) async {
    final r = await http
        .post(_local('/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'question': question,
              'limit': limit,
              if (settings.localSummary != 'auto' && settings.localSummary != 'extractive')
                'summary_model': settings.localSummary,
            }))
        .timeout(const Duration(minutes: 4));
    if (r.statusCode != 200) throw _fail(r);
    final answer = AskAnswer.fromJson(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
    if (answer.answer.isEmpty && answer.sources.isEmpty) return null;
    return answer;
  }

  /// Write an answer over passages the app already retrieved.
  ///
  /// Retrieval is local (see `SearchIndex`); this only decides who writes the
  /// prose. Two answerers are used, whichever is available:
  ///  * **on this device** — the chosen on-device summary model, or any installed
  ///    GGUF when there is no connected service to ask;
  ///  * **a connected service** — the external API when the summary half is
  ///    External, or the machine's `/chat` when it is On this machine.
  ///
  /// A service that is not there costs one short probe, not a connect timeout, and
  /// is not an error: the phone's own model takes over. `null` means no model
  /// wrote it, and the caller shows the passages themselves.
  Future<AskAnswer?> answer(String question, List<AskHit> hits) async {
    if (hits.isEmpty) return null;
    if (settings.summaryOnDevice) return _deviceAnswer(question, hits);
    if (settings.summaryExternal) {
      try {
        final text = await _answerExternal(question, hits);
        if (text != null) return _cited(text, hits, 'external · ${settings.externalSummary}');
      } on Exception catch (e) {
        // A service that cannot be reached falls back to the phone; one that
        // answers with an error (a rejected key, say) is a real problem and stays.
        final unreachable = e is SocketException ||
            e is http.ClientException ||
            e is TimeoutException;
        if (!unreachable) rethrow;
      }
      return _deviceAnswer(question, hits);
    }
    if (await _serviceConnected()) {
      try {
        final fromMachine = await ask(question, limit: hits.length);
        if (fromMachine != null && fromMachine.answer.isNotEmpty) return fromMachine;
      } catch (_) {
        // A service that answers badly is the same as one that is not there.
      }
    }
    return _deviceAnswer(question, hits);
  }

  /// The on-device model, when one is installed; null otherwise (extractive).
  Future<AskAnswer?> _deviceAnswer(String question, List<AskHit> hits) async {
    final result = await device.answer(question, hits);
    if (result == null) return null;
    return _cited(result.text, hits, result.engine);
  }

  /// True when the machine's service answers `GET /health`.
  ///
  /// Asked before `/chat` so a phone with no PC next to it moves on to its own
  /// model in a second instead of waiting out a TCP connect timeout.
  Future<bool> _serviceConnected() async {
    try {
      final r = await http.get(_local('/health')).timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Mark the sources the answer actually cited, and keep their order.
  static AskAnswer _cited(String text, List<AskHit> hits, String engine) {
    final cited = <int>{};
    for (final m in RegExp(r'\[(\d+)\]').allMatches(text)) {
      final n = int.tryParse(m.group(1)!);
      if (n != null && n >= 1 && n <= hits.length) cited.add(n);
    }
    for (var i = 0; i < hits.length; i++) {
      hits[i].cited = cited.contains(i + 1);
    }
    return AskAnswer(answer: text.trim(), engine: engine, sources: hits);
  }

  Future<String?> _answerExternal(String question, List<AskHit> hits) async {
    final excerpts = [
      for (var i = 0; i < hits.length; i++) hits[i].excerpt(i + 1),
    ].join('\n');
    final prompt = 'You answer questions about the user\'s recorded notes.\n'
        'Use ONLY the numbered excerpts below. After each fact, cite the excerpt number in '
        'square brackets, like [2]. If the excerpts do not contain the answer, say so in one '
        'short sentence — do not guess and do not invent names, dates or numbers.\n'
        'Answer in the language of the question. Be brief.\n\n'
        'EXCERPTS\n$excerpts\n\nQUESTION: $question';
    final r = await http
        .post(_external('/chat/completions'),
            headers: {'Content-Type': 'application/json', ..._auth},
            body: jsonEncode({
              'model': settings.externalSummary,
              'temperature': 0.2,
              'max_tokens': 400,
              'messages': [
                {
                  'role': 'system',
                  'content': 'You answer only from the given excerpts, with citations.',
                },
                {'role': 'user', 'content': prompt},
              ],
            }))
        .timeout(const Duration(minutes: 2));
    if (r.statusCode != 200) throw _fail(r);
    final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final text = body['choices'][0]['message']['content'].toString().trim();
    return text.isEmpty ? null : text;
  }

  /// Transcribe [audio]. [languages] are whisper codes the take may contain,
  /// most likely first; empty means let the backend detect. See
  /// [SpeechLanguages] for how each half uses the list.
  Future<Map<String, dynamic>> transcribe(File audio,
      {Duration timeout = const Duration(minutes: 10),
      List<String> languages = const []}) async {
    final chosen = SpeechLanguages.sanitise(languages);
    if (settings.speechOnDevice) return device.transcribe(audio, languages: chosen);
    if (settings.speechExternal) return _transcribeExternal(audio, timeout, chosen);
    final bytes = await audio.readAsBytes();
    final uri = _local('/transcribe', {
      'model': settings.localSpeech,
      if (chosen.isNotEmpty) 'languages': chosen.join(','),
    });
    final r = await http
        .post(uri, headers: {'Content-Type': 'application/octet-stream'}, body: bytes)
        .timeout(timeout);
    if (r.statusCode != 200) throw _fail(r);
    final json = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    json['engine'] = 'local · whisper ${json['model'] ?? settings.localSpeech}';
    return json;
  }

  Future<Map<String, dynamic>> _transcribeExternal(
      File audio, Duration timeout, List<String> languages) async {
    final forced = SpeechLanguages.forceFor(languages);
    var body = await _postAudio(audio, timeout, forced);
    // More than one language named: the service detects across the take. Only
    // when that guess lands outside the list is the first choice forced and the
    // audio uploaded again — a second upload is the expensive part.
    if (languages.length > 1 &&
        !SpeechLanguages.covers(languages, (body['language'] ?? '').toString())) {
      body = await _postAudio(audio, timeout, languages.first);
    }
    final segments = <Map<String, dynamic>>[];
    for (final s in (body['segments'] as List? ?? const [])) {
      if (s is Map) {
        segments.add({
          'start': (s['start'] ?? 0),
          'end': (s['end'] ?? 0),
          'text': (s['text'] ?? '').toString().trim(),
        });
      }
    }
    if (segments.isEmpty && (body['text'] ?? '').toString().isNotEmpty) {
      segments.add({'start': 0, 'end': 0, 'text': body['text'].toString().trim()});
    }
    return {
      'source': audio.path,
      'language': (body['language'] ?? '').toString(),
      'duration': (body['duration'] ?? 0),
      'segments': segments,
      'engine': 'external · ${settings.externalSpeech}',
    };
  }

  /// One `/audio/transcriptions` call, with [language] forced when it is not
  /// empty.
  Future<Map<String, dynamic>> _postAudio(
      File audio, Duration timeout, String language) async {
    final req = http.MultipartRequest('POST', _external('/audio/transcriptions'))
      ..headers.addAll(_auth)
      ..fields['model'] = settings.externalSpeech
      ..fields['response_format'] = 'verbose_json';
    if (language.isNotEmpty) req.fields['language'] = language;
    req.files.add(await http.MultipartFile.fromPath('file', audio.path));
    final streamed = await req.send().timeout(timeout);
    final r = await http.Response.fromStream(streamed);
    if (r.statusCode != 200) throw _fail(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> summarize(Map<String, dynamic> transcript,
      {String template = 'meeting', Duration timeout = const Duration(minutes: 3)}) async {
    if (settings.summaryOnDevice) {
      return device.summarize(transcript, template: template);
    }
    if (!settings.summaryExternal) {
      final r = await http
          .post(_local('/summarize'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'transcript': transcript,
                'template': template,
                if (settings.localSummary == 'extractive') 'prefer_llm': false,
                if (settings.localSummary != 'auto' && settings.localSummary != 'extractive')
                  'summary_model': settings.localSummary,
              }))
          .timeout(timeout);
      if (r.statusCode != 200) throw _fail(r);
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    }

    final order = summaryTemplates[template] ?? summaryTemplates['plain']!;
    final keys = order.map((k) => '"$k"').join(', ');
    final prompt = 'Summarise this transcript.\n'
        'Reply with JSON only, with exactly these keys in this order: $keys.\n'
        'Each value is an array of short plain-text bullet strings drawn from the transcript. '
        'Use the language of the transcript. No markdown, no numbering, no extra keys. '
        'Do not invent anything.\n\nTRANSCRIPT:\n'
        '${(transcript['segments'] as List? ?? const []).map((s) => s['text']).join(' ')}';
    final r = await http
        .post(_external('/chat/completions'),
            headers: {'Content-Type': 'application/json', ..._auth},
            body: jsonEncode({
              'model': settings.externalSummary,
              'temperature': 0.2,
              'max_tokens': 800,
              'messages': [
                {'role': 'system', 'content': 'You write terse, factual notes as compact JSON.'},
                {'role': 'user', 'content': prompt},
              ],
            }))
        .timeout(timeout);
    if (r.statusCode != 200) throw _fail(r);
    final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final content = body['choices'][0]['message']['content'].toString();
    final match = RegExp(r'\{.*\}', dotAll: true).firstMatch(content);
    if (match == null) throw Exception('the model did not return JSON');
    final raw = jsonDecode(match.group(0)!) as Map<String, dynamic>;
    final sections = normaliseSections(raw, template);
    if (sections.values.every((v) => v.isEmpty)) {
      throw Exception('the model returned no summary sections');
    }
    return {
      'template': template,
      'engine': 'external · ${settings.externalSummary}',
      'sections': sections,
    };
  }

  /// A short title for a transcript. On-device and local summary modes ask the
  /// GGUF (or lead-in fallback); external summary mode uses the chat model.
  Future<String?> title(Map<String, dynamic> transcript) async {
    if (settings.summaryOnDevice) return device.title(transcript);
    final parts = [
      for (final s in (transcript['segments'] as List? ?? const [])) s['text'],
    ];
    final text = parts.join(' ').trim();
    if (text.isEmpty) return null;
    final excerpt = text.length > 4000 ? text.substring(0, 4000) : text;
    try {
      if (settings.summaryExternal) {
        final r = await http
            .post(_external('/chat/completions'),
                headers: {'Content-Type': 'application/json', ..._auth},
                body: jsonEncode({
                  'model': settings.externalSummary,
                  'temperature': 0.3,
                  'max_tokens': 24,
                  'messages': [
                    {'role': 'system', 'content': 'You write very short, specific titles.'},
                    {
                      'role': 'user',
                      'content': 'Give this transcript a title of 3 to 6 words in its own '
                          'language. Reply with the title only.\n\n$excerpt',
                    },
                  ],
                }))
            .timeout(const Duration(seconds: 60));
        if (r.statusCode != 200) return null;
        final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        final raw = body['choices'][0]['message']['content'].toString().trim();
        // Chat models answer "null", a quoted phrase or a whole paragraph often
        // enough that the reply is not trusted as a title on its own.
        return cleanTitle(raw);
      }
      final r = await http
          .post(_local('/title'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'transcript': transcript,
                if (settings.localSummary != 'auto' && settings.localSummary != 'extractive')
                  'summary_model': settings.localSummary,
              }))
          .timeout(const Duration(seconds: 90));
      if (r.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      return cleanTitle((body['title'] ?? '').toString());
    } catch (_) {
      return null;
    }
  }

  Exception _fail(http.Response r) {
    try {
      final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final err = body['error'];
      final msg = err is Map ? (err['message'] ?? err) : err;
      return Exception(msg ?? 'request failed (${r.statusCode})');
    } catch (_) {
      return Exception('request failed (${r.statusCode})');
    }
  }
}
