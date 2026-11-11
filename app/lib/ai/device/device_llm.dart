import 'dart:convert';

import 'package:llamadart/llamadart.dart';

import '../notes.dart';

/// GGUF summaries on the device, through llama.cpp (llamadart).
///
/// Runs in its own isolate, like whisper: load, generate, return the sections,
/// exit. Nothing leaves the phone and nothing is metered. If the model cannot
/// answer — missing file, out of memory, not-JSON — this returns `null` and the
/// caller falls back to the extractive summary, which is a real summary and not
/// an error.
const String _systemPrompt = 'You write terse factual notes as compact JSON.';

/// Long takes are trimmed before the prompt: a 4k context overflows, and an
/// overflowing transcript produces broken JSON rather than a shorter summary.
const int _maxTranscriptChars = 12000;

Future<Map<String, dynamic>?> summarizeWithGguf({
  required String ggufPath,
  required String transcriptText,
  required String template,
  required String modelLabel,
  String language = '',
  int maxTokens = 512,
}) async {
  final safeTemplate = summaryTemplates.containsKey(template) ? template : 'plain';
  final order = summaryTemplates[safeTemplate]!;
  final schema = jsonEncode({for (final name in order) name: <String>[]});
  final text = transcriptText.length > _maxTranscriptChars
      ? transcriptText.substring(0, _maxTranscriptChars)
      : transcriptText;

  final prompt = 'Summarise the transcript. Reply with JSON only, no prose, using exactly '
      'this shape (same keys, same order): $schema\n'
      'Each value is a list of short plain-text bullet strings drawn from the transcript. '
      'Every key needs at least one bullet; Overview states what the recording is about in '
      'one or two sentences. Use the language of the transcript. No markdown, no numbering.'
      '\n\nTRANSCRIPT:\n$text';

  // Constrain the decoder to the template's keys. A 0.5B invents headings and
  // returns empty arrays without this; a backend that cannot honour the schema
  // still gets the prompt and the regex below.
  final responseFormat = <String, dynamic>{
    'type': 'json_schema',
    'json_schema': {
      'schema': {
        'type': 'object',
        'properties': {
          for (final name in order)
            name: {
              'type': 'array',
              'items': {'type': 'string'},
              'minItems': 1,
            },
        },
        'required': order,
        'additionalProperties': false,
      },
    },
  };

  final reply = await _generate(
    ggufPath: ggufPath,
    system: _systemPrompt,
    prompt: prompt,
    maxTokens: maxTokens,
    temp: 0.2,
    responseFormat: responseFormat,
  );
  if (reply == null) return null;

  final match = RegExp(r'\{.*\}', dotAll: true).firstMatch(reply);
  if (match == null) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(match.group(0)!);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;

  final sections = normaliseSections(decoded, safeTemplate);
  if (sections.values.every((b) => b.isEmpty)) return null;
  return {
    'template': safeTemplate,
    'engine': 'on device · llama.cpp · $modelLabel',
    'sections': sections,
    if (language.isNotEmpty) 'language': language,
  };
}

/// A short answer that cites the numbered excerpts it used.
///
/// [excerpts] are already-retrieved passages, one per line, each prefixed with
/// `[n] `. Retrieval happens in the app (see `search_index.dart`), so the model
/// never sees more of the library than the few passages that mattered.
Future<String?> answerWithGguf({
  required String ggufPath,
  required String question,
  required String excerpts,
  int maxTokens = 400,
}) async {
  final prompt = 'You answer questions about the user\'s recorded notes.\n'
      'Use ONLY the numbered excerpts below. After each fact, cite the excerpt number in\n'
      'square brackets, like [2]. If the excerpts do not contain the answer, say so in one\n'
      'short sentence — do not guess and do not invent names, dates or numbers.\n'
      'Answer in the language of the question. Be brief: one to three sentences, or a\n'
      'short list when the question asks for several things.\n\n'
      'EXCERPTS\n$excerpts\n\nQUESTION: $question';
  final reply = await _generate(
    ggufPath: ggufPath,
    system: 'You answer only from the given excerpts, with citations.',
    prompt: prompt,
    maxTokens: maxTokens,
    temp: 0.2,
  );
  final text = reply?.trim();
  return (text == null || text.isEmpty) ? null : text;
}

/// A short, specific title even when it is rephrased rather than extracted.
Future<String?> titleWithGguf({
  required String ggufPath,
  required String transcriptText,
}) async {
  final excerpt =
      transcriptText.length > 4000 ? transcriptText.substring(0, 4000) : transcriptText;
  final reply = await _generate(
    ggufPath: ggufPath,
    system: 'You write very short, specific titles.',
    prompt: 'Give this transcript a title of 3 to 6 words. Use the language of the '
        'transcript. Reply with the title only, no quotes, no punctuation at the end.'
        '\n\n$excerpt',
    maxTokens: 24,
    temp: 0.3,
  );
  if (reply == null) return null;
  final first = reply.trim().split(RegExp(r'[\r\n]+')).first;
  // Model names sometimes come back quoted; strip the wrapping quotes and a
  // trailing full stop without a regex that has to escape both quote kinds.
  final title = first
      .replaceAll(RegExp(r'''^[\s"']+|[\s"']+$'''), '')
      .replaceAll(RegExp(r'[.,:;-]+$'), '');
  return title.isEmpty ? null : title;
}

Future<String?> _generate({
  required String ggufPath,
  required String system,
  required String prompt,
  required int maxTokens,
  required double temp,
  Map<String, dynamic>? responseFormat,
}) async {
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.path(ggufPath)),
    // A phone has no business reserving the model's full 32k context: 4k holds
    // this prompt and the answer, and keeps the KV cache small. CPU only, so a
    // driver with a broken Vulkan path cannot turn a summary into a crash.
    params: const ModelParams(
      contextSize: 4096,
      device: ComputeDevice.cpu,
      gpuLayers: 0,
    ),
  );
  try {
    final messages = [
      LlamaChatMessage.fromText(role: LlamaChatRole.system, text: system),
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt),
    ];
    final params = GenerationParams(
      maxTokens: maxTokens,
      temp: temp,
      topK: 40,
      topP: 0.9,
      penalty: 1.1,
    );
    LlamaCompletion completion;
    try {
      completion = await engine.complete(messages,
          params: params, enableThinking: false, responseFormat: responseFormat);
    } catch (_) {
      // Not every backend/runtime combination supports a response format.
      if (responseFormat == null) rethrow;
      completion = await engine.complete(messages, params: params, enableThinking: false);
    }
    final text = completion.text.trim();
    return text.isEmpty ? null : text;
  } catch (_) {
    return null;
  } finally {
    await engine.dispose();
  }
}
