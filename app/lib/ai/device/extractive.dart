import 'dart:math' as math;

import '../notes.dart';

/// Extractive summaries, on the device, with no model at all.
///
/// The same algorithm as `notra/ai.py:summarize_extractive`, so a take summarised
/// on the phone and one summarised by the service read alike: real sentences from
/// the transcript, ranked by term frequency, nothing invented. It needs no
/// download and never calls out, which makes it the honest fallback when a GGUF
/// is missing — and the fastest option for short takes.
const Set<String> _stopwords = {
  'a', 'about', 'above', 'after', 'again', 'against', 'all', 'am', 'an', 'and', 'any',
  'are', 'as', 'at', 'be', 'because', 'been', 'before', 'being', 'below', 'between',
  'both', 'but', 'by', 'can', 'could', 'did', 'do', 'does', 'doing', 'down', 'during',
  'each', 'few', 'for', 'from', 'further', 'had', 'has', 'have', 'having', 'he', 'her',
  'here', 'hers', 'herself', 'him', 'himself', 'his', 'how', 'i', 'if', 'in', 'into',
  'is', 'it', 'its', 'itself', 'just', 'me', 'more', 'most', 'my', 'myself', 'no', 'nor',
  'not', 'now', 'of', 'off', 'on', 'once', 'only', 'or', 'other', 'our', 'ours',
  'ourselves', 'out', 'over', 'own', 'same', 'she', 'should', 'so', 'some', 'such',
  'than', 'that', 'the', 'their', 'theirs', 'them', 'themselves', 'then', 'there',
  'these', 'they', 'this', 'those', 'through', 'to', 'too', 'under', 'until', 'up',
  'very', 'was', 'we', 'were', 'what', 'when', 'where', 'which', 'while', 'who', 'whom',
  'why', 'will', 'with', 'you', 'your', 'yours', 'yourself', 'yourselves', 'okay', 'ok',
  'yeah', 'yes', 'um', 'uh', 'oh', 'like', 'really', 'going', 'gonna', 'got', 'get',
  'sort', 'kind', 'thing', 'things',
};

/// Phrases that mark a decision or a commitment, used to fill "Decisions & actions".
const List<String> _actionCues = [
  'will ', 'we need', 'need to', 'have to', 'should ', "let's", 'lets ', 'going to',
  'next step', 'action', 'by monday', 'by friday', 'remember', 'todo', 'to do',
];

/// A word, in any script: Latin, Cyrillic, Greek, CJK, Arabic… Unlike the
/// service's `[a-zA-Z']+`, this keeps term frequency meaningful for a transcript
/// that is not in English.
final RegExp _word = RegExp(r"[\p{L}\p{N}']+", unicode: true);

/// Sentence boundaries, including the scripts that do not use a Latin full stop.
final RegExp _boundary = RegExp(r'(?<=[.!?。！？])\s*');

List<String> _sentences(String text) {
  final parts = text.split(_boundary);
  final out = <String>[];
  for (final part in parts) {
    final clean = part.trim();
    if (clean.isEmpty) continue;
    // A Latin sentence is a handful of words; a CJK one has no spaces at all, so
    // length stands in for the word count there.
    final words = clean.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    if (words >= 3 || clean.length >= 12) out.add(clean);
  }
  if (out.isNotEmpty) return out;
  return text.trim().isEmpty ? const [] : [text.trim()];
}

List<String> _terms(String sentence) => [
      for (final m in _word.allMatches(sentence.toLowerCase()))
        if (m.group(0)!.length >= 3 && !_stopwords.contains(m.group(0)!)) m.group(0)!,
    ];

/// (score, index) per sentence, scored the way the service scores them: shared
/// terms win, earlier sentences carry the framing, rambles are discounted.
List<double> _score(List<String> sentences) {
  final freq = <String, int>{};
  for (final s in sentences) {
    for (final w in _terms(s)) {
      freq[w] = (freq[w] ?? 0) + 1;
    }
  }
  final total = sentences.length;
  final scores = <double>[];
  for (var i = 0; i < sentences.length; i++) {
    final words = _terms(sentences[i]);
    var score = words.isEmpty
        ? 0.0
        : words.fold<int>(0, (sum, w) => sum + (freq[w] ?? 0)) / math.sqrt(words.length);
    score *= 1.0 + 0.35 * (1 - i / (total < 1 ? 1 : total));
    final length = sentences[i].split(RegExp(r'\s+')).length;
    score /= 1.0 + 0.02 * (length > 18 ? length - 18 : 0);
    scores.add(score);
  }
  return scores;
}

/// Template-shaped summary built from the transcript's own sentences.
///
/// [transcript] is the same JSON the service takes: `{segments: [{text}], language}`.
Map<String, dynamic> extractiveSummary(Map<String, dynamic> transcript, String template) {
  final safeTemplate = summaryTemplates.containsKey(template) ? template : 'plain';
  final order = summaryTemplates[safeTemplate]!;
  final text = [
    for (final s in (transcript['segments'] as List? ?? const []))
      if (s is Map) (s['text'] ?? '').toString(),
  ].join(' ').trim();

  final sentences = _sentences(text);
  if (sentences.isEmpty) {
    return {
      'template': safeTemplate,
      'engine': 'extractive · on device',
      'sections': <String, List<String>>{},
    };
  }

  final scores = _score(sentences);
  final ranked = [for (var i = 0; i < sentences.length; i++) i]
    ..sort((a, b) {
      final byScore = scores[b].compareTo(scores[a]);
      if (byScore != 0) return byScore;
      return b.compareTo(a);
    });
  final picked = <int>{};

  List<String> take(int n) {
    final out = <String>[];
    for (final i in ranked) {
      if (picked.contains(i)) continue;
      picked.add(i);
      out.add(sentences[i]);
      if (out.length >= n) break;
    }
    return out;
  }

  final sections = <String, List<String>>{for (final name in order) name: []};

  sections['Overview'] = take(sentences.length < 4 ? 1 : 2);

  final actions = [
    for (final i in ranked)
      if (!picked.contains(i) &&
          _actionCues.any((cue) => sentences[i].toLowerCase().contains(cue)))
        i,
  ];
  if (sections.containsKey('Decisions & actions')) {
    for (final i in actions.take(3)) {
      sections['Decisions & actions']!.add(sentences[i]);
      picked.add(i);
    }
  }

  final remainingKey = safeTemplate == 'lecture' ? 'Key concepts' : 'Key points';
  sections[remainingKey] = take(sentences.length > 4 ? 3 : 2);

  if (safeTemplate == 'lecture') sections['To review'] = [];

  final language = (transcript['language'] ?? '').toString();
  return {
    'template': safeTemplate,
    'engine': 'extractive · on device',
    'sections': sections,
    'word_count': text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length,
    if (language.isNotEmpty) 'language': language,
  };
}
