import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';
import 'notes.dart';

/// Client for transcription/summaries.
///
/// Two backends, chosen independently for each job in [AiSettings]:
///  * local  — `scripts/ai_server.py` (whisper + a local GGUF, or extractive)
///  * external — any OpenAI-compatible API (`/audio/transcriptions` +
///    `/chat/completions`).
///
/// So local speech can feed an external summary model, and the other way round.
class AiClient {
  AiClient(this.settings);

  final AiSettings settings;

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
    return 'No AI service found (${tried.join(', ')}) — start scripts/ai_server.py';
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

  Future<Map<String, dynamic>> transcribe(File audio,
      {Duration timeout = const Duration(minutes: 10)}) async {
    if (settings.speechExternal) return _transcribeExternal(audio, timeout);
    final bytes = await audio.readAsBytes();
    final uri = _local('/transcribe', {'model': settings.localSpeech});
    final r = await http
        .post(uri, headers: {'Content-Type': 'application/octet-stream'}, body: bytes)
        .timeout(timeout);
    if (r.statusCode != 200) throw _fail(r);
    final json = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    json['engine'] = 'local · whisper ${json['model'] ?? settings.localSpeech}';
    return json;
  }

  Future<Map<String, dynamic>> _transcribeExternal(File audio, Duration timeout) async {
    final req = http.MultipartRequest('POST', _external('/audio/transcriptions'))
      ..headers.addAll(_auth)
      ..fields['model'] = settings.externalSpeech
      ..fields['response_format'] = 'verbose_json'
      ..files.add(await http.MultipartFile.fromPath('file', audio.path));
    final streamed = await req.send().timeout(timeout);
    final r = await http.Response.fromStream(streamed);
    if (r.statusCode != 200) throw _fail(r);
    final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
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

  Future<Map<String, dynamic>> summarize(Map<String, dynamic> transcript,
      {String template = 'meeting', Duration timeout = const Duration(minutes: 3)}) async {
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

  /// A short title for a transcript. Local summary mode asks the service (GGUF or
  /// lead-in fallback); external summary mode uses the chat model.
  Future<String?> title(Map<String, dynamic> transcript) async {
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
        final first = raw.split('\n').first.trim().replaceAll('"', '').replaceAll("'", '');
        return first.isEmpty ? null : first;
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
      final title = (body['title'] ?? '').toString().trim();
      return title.isEmpty ? null : title;
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
