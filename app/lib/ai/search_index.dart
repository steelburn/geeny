/// Search over the notes the app already has, on the phone itself.
///
/// A Dart port of `notra/search.py`, kept deliberately close to it so a query
/// ranks the same way whether it is answered here or by the machine's service.
/// The corpus is transcript segments and summary sections — never audio — and it
/// lives in memory, rebuilt from the library whenever the notes change.
///
/// This is what makes Search and Ask work when no AI service is running: the
/// index is in the app, retrieval is local, and only the prose of an answer (when
/// a model is configured at all) leaves this file.
library;

import 'dart:math' as math;

import 'ask.dart';

/// Segment runs are cut at this size so a hit is a line or two, not a wall.
const int _chunkChars = 700;
const int _chunkSegments = 8;

const int _snippetChars = 280;

/// Words, plus CJK character bigrams so scripts without spaces still match.
final RegExp _word = RegExp(
  r"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?",
  unicode: true,
);
final RegExp _cjk = RegExp(
  r'[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]+',
);
final RegExp _whitespace = RegExp(r'\s+');
final RegExp _trailingPunctuation = RegExp(r'[ ,;:]+$');

/// Words that carry no retrieval signal. Deliberately small: the IDF term already
/// damps common words, and over-filtering breaks short questions like "who owns
/// the sampling plan?".
const Set<String> questionStopwords = {
  'a', 'an', 'the', 'of', 'to', 'in', 'on', 'at', 'for', 'from', 'by', 'with',
  'and', 'or', 'but', 'is', 'are', 'was', 'were', 'be', 'been', 'being', 'do',
  'does', 'did', 'done', 'have', 'has', 'had', 'what', 'when', 'where', 'which',
  'who', 'whom', 'whose', 'why', 'how', 'that', 'this', 'these', 'those', 'it',
  'its', 'as', 'if', 'then', 'than', 'so', 'we', 'you', 'i', 'he', 'she', 'they',
  'them', 'our', 'your', 'their', 'tell', 'show', 'find', 'me', 'about', 'any',
  'all', 'into', 'over', 'under', 'more', 'most', 'other', 'some', 'such', 'can',
  'could', 'would', 'should', 'will', 'shall', 'may', 'might', 'must',
};

List<String> tokenize(String text) {
  final lower = text.toLowerCase();
  final out = <String>[];
  for (final m in _word.allMatches(lower)) {
    out.add(m.group(0)!);
  }
  for (final run in _cjk.allMatches(lower)) {
    final s = run.group(0)!;
    for (var i = 0; i + 1 < s.length; i++) {
      out.add(s.substring(i, i + 2));
    }
  }
  return out;
}

/// Query words with the question filler removed; never empty for real text.
List<String> queryTerms(String query) {
  final terms = tokenize(query);
  final kept = [
    for (final t in terms)
      if (!questionStopwords.contains(t)) t,
  ];
  return kept.isEmpty ? terms : kept;
}

String _clean(Object? value) =>
    (value?.toString() ?? '').replaceAll(_whitespace, ' ').trim();

String _snippet(String text) {
  final clean = _clean(text);
  if (clean.length <= _snippetChars) return clean;
  var cut = clean.substring(0, _snippetChars);
  final space = cut.lastIndexOf(' ');
  if (space > _snippetChars * 0.6) cut = cut.substring(0, space);
  return '${cut.replaceFirst(_trailingPunctuation, '')}…';
}

double? _num(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

/// One retrievable block: a summary section or a run of transcript segments.
class _Passage {
  _Passage({
    required this.id,
    required this.title,
    required this.date,
    required this.project,
    required this.section,
    required this.text,
    this.start,
    this.end,
  });

  final String id;
  final String title;
  final String date;
  final String project;
  final String section; // "Summary" passages carry the section name
  final String text;
  final double? start; // seconds into the take, null for a summary passage
  final double? end;

  Map<String, int> terms = const {};

  AskHit hit(double score) => AskHit(
        id: id,
        title: title,
        text: _snippet(text),
        date: date,
        project: project,
        section: section,
        start: start,
        score: double.parse(score.toStringAsFixed(3)),
      );
}

/// Summary sections first, then timestamped runs of the transcript.
List<_Passage> _passagesFor(Map<String, dynamic> doc) {
  final id = _clean(doc['id'] ?? doc['path']);
  final title = _clean(doc['title']).isEmpty ? id : _clean(doc['title']);
  final date = _clean(doc['date']);
  final project = _clean(doc['project']);
  final out = <_Passage>[];

  final summary = doc['summary'];
  Map<String, dynamic> sections = const {};
  if (summary is Map) {
    final inner = summary['sections'];
    final source = inner is Map ? inner : summary;
    sections = {
      for (final e in source.entries) e.key.toString(): e.value,
    };
  }
  for (final entry in sections.entries) {
    final raw = entry.value;
    final bullets = raw is String
        ? [raw]
        : raw is List
            ? raw
            : const [];
    final body = [
      for (final b in bullets)
        if (_clean(b).isNotEmpty) _clean(b),
    ].join(' ');
    if (body.isEmpty) continue;
    final name = _clean(entry.key);
    out.add(_Passage(
      id: id,
      title: title,
      date: date,
      project: project,
      section: name.isEmpty ? 'Summary' : name,
      text: body,
    ));
  }

  final segments = <Map>[
    for (final s in (doc['segments'] as List? ?? const []))
      if (s is Map && _clean(s['text']).isNotEmpty) s,
  ];
  var run = <Map>[];
  var chars = 0;

  void flush() {
    if (run.isEmpty) return;
    final text = [for (final s in run) _clean(s['text'])].join(' ');
    final first = run.first;
    final last = run.last;
    final speaker = _clean(first['speaker']);
    out.add(_Passage(
      id: id,
      title: title,
      date: date,
      project: project,
      section: speaker.isEmpty ? 'Transcript' : speaker,
      text: text,
      start: _num(first['start']),
      end: _num(last['end']),
    ));
    run = [];
    chars = 0;
  }

  for (final seg in segments) {
    // A speaker change starts a new passage: reading "Speaker 2:" first is how a
    // person finds the answer in the take.
    if (run.isNotEmpty && _clean(seg['speaker']) != _clean(run.first['speaker'])) {
      flush();
    }
    run.add(seg);
    chars += _clean(seg['text']).length + 1;
    if (chars >= _chunkChars || run.length >= _chunkSegments) flush();
  }
  flush();
  return out;
}

/// BM25 over passages. Small enough to rebuild whenever the notes change.
class SearchIndex {
  /// Term-frequency saturation and length normalisation, the usual BM25 defaults.
  static const double _k1 = 1.2;
  static const double _b = 0.75;

  final List<_Passage> _passages = [];
  final Map<String, int> _df = {};
  double _avgLength = 1;
  int _documentCount = 0;

  /// Takes in the index (a take with neither transcript nor summary is not one).
  int get documentCount => _documentCount;

  /// Retrievable blocks across every take.
  int get passageCount => _passages.length;

  void replace(List<Map<String, dynamic>> documents) {
    _passages.clear();
    final ids = <String>{};
    for (final doc in documents) {
      final id = _clean(doc['id'] ?? doc['path']);
      if (id.isEmpty) continue;
      final passages = _passagesFor(doc);
      if (passages.isEmpty) continue;
      ids.add(id);
      _passages.addAll(passages);
    }
    _documentCount = ids.length;

    _df.clear();
    var total = 0;
    for (final passage in _passages) {
      // The title is a strong signal ("Sampling" questions should reach that
      // take), so it is indexed twice alongside the body.
      final tokens = <String>[
        ...tokenize(passage.text),
        ...tokenize(passage.title),
        ...tokenize(passage.title),
        ...tokenize(passage.project),
      ];
      final terms = <String, int>{};
      for (final token in tokens) {
        terms[token] = (terms[token] ?? 0) + 1;
      }
      passage.terms = terms;
      total += tokens.length;
      for (final term in terms.keys) {
        _df[term] = (_df[term] ?? 0) + 1;
      }
    }
    _avgLength = _passages.isEmpty ? 1 : total / _passages.length;
  }

  double _idf(String term) {
    final n = _passages.length;
    if (n == 0) return 0;
    final df = _df[term] ?? 0;
    return math.log(1 + (n - df + 0.5) / (df + 0.5));
  }

  List<AskHit> search(String query, {int limit = 12}) {
    final terms = queryTerms(query);
    if (terms.isEmpty || _passages.isEmpty) return const [];
    final phrase = _clean(query).toLowerCase();
    final seen = terms.toSet().toList();

    final scored = <({double score, _Passage passage})>[];
    for (final passage in _passages) {
      var length = 0;
      for (final count in passage.terms.values) {
        length += count;
      }
      if (length == 0) length = 1;
      var score = 0.0;
      for (final term in seen) {
        final tf = passage.terms[term] ?? 0;
        if (tf == 0) continue;
        final norm = _k1 * (1 - _b + _b * length / _avgLength);
        score += _idf(term) * (tf * (_k1 + 1)) / (tf + norm);
      }
      if (score <= 0) continue;
      // An exact phrase match is a much stronger signal than any single word.
      if (phrase.length > 3 && passage.text.toLowerCase().contains(phrase)) {
        score *= 1.4;
      }
      if (passage.start == null) score *= 1.08; // a section summary is a digest
      scored.add((score: score, passage: passage));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final capped = math.max(1, limit);
    return [
      for (final entry in scored.take(capped)) entry.passage.hit(entry.score),
    ];
  }
}

/// The passages themselves as the answer, for when no model writes one.
///
/// Never pretends otherwise: the engine says `extractive` and the sheet says so.
AskAnswer extractiveAnswer(List<AskHit> hits, {int show = 3}) {
  final cited = math.min(show, hits.length);
  final body = [for (final hit in hits.take(show)) hit.text].join('\n\n');
  for (var i = 0; i < hits.length; i++) {
    hits[i].cited = i < cited;
  }
  return AskAnswer(
    answer: body,
    engine: 'extractive · matching passages',
    sources: List<AskHit>.unmodifiable(hits),
  );
}
