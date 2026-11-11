/// Section order per template. Models return them in arbitrary order (and
/// sometimes with different names); the app always reads and displays them in
/// this order so two runs do not look like two different formats.
const Map<String, List<String>> summaryTemplates = {
  'meeting': ['Overview', 'Decisions & actions', 'Key points'],
  'lecture': ['Overview', 'Key concepts', 'To review'],
  'plain': ['Overview', 'Key points'],
};

/// Names a model uses for the canonical sections above.
const Map<String, List<String>> _sectionAliases = {
  'overview': ['summary', 'tldr', 'abstract', 'purpose', 'overview & context'],
  'decisions & actions': [
    'decisions',
    'actions',
    'action items',
    'next steps',
    'decisions and actions',
    'decisions actions',
  ],
  'key points': ['points', 'highlights', 'takeaways', 'key takeaways', 'main points'],
  'key concepts': ['concepts', 'key ideas', 'terms', 'definitions'],
  'to review': ['review', 'follow up', 'follow ups', 'follow-ups', 'questions'],
};

String _sectionKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

List<String> _bullets(dynamic value) {
  final out = <String>[];
  void add(dynamic v) {
    if (v == null) return;
    if (v is Map) {
      for (final nested in v.values) {
        add(nested);
      }
      return;
    }
    if (v is Iterable) {
      for (final nested in v) {
        add(nested);
      }
      return;
    }
    for (final line in v.toString().split(RegExp(r'[\r\n]+'))) {
      var clean = line.trim();
      clean = clean.replaceFirst(RegExp(r'^[-*•·]+\s*'), '');
      clean = clean.replaceFirst(RegExp(r'^\d+[.)]\s*'), '');
      clean = clean.trim();
      if (clean.isNotEmpty) out.add(clean);
    }
  }

  add(value);
  return out;
}

/// Map a model's raw `sections` object onto the template's canonical headings,
/// in template order, with plain bullet strings. Unknown sections are kept after
/// the canonical ones rather than silently discarded.
Map<String, List<String>> normaliseSections(Map<dynamic, dynamic> raw, String template) {
  final order = summaryTemplates[template] ?? summaryTemplates['plain']!;
  final canonical = {for (final name in order) _sectionKey(name): name};
  final aliases = <String, String>{};
  for (final entry in _sectionAliases.entries) {
    final target = canonical[_sectionKey(entry.key)];
    if (target == null) continue;
    for (final alias in entry.value) {
      aliases[_sectionKey(alias)] = target;
    }
  }

  final out = {for (final name in order) name: <String>[]};
  final extras = <String, List<String>>{};
  for (final entry in raw.entries) {
    final key = _sectionKey(entry.key.toString());
    final target = canonical[key] ?? aliases[key];
    final bullets = _bullets(entry.value);
    if (target != null) {
      out[target]!.addAll(bullets);
    } else if (bullets.isNotEmpty) {
      extras[entry.key.toString()] = bullets;
    }
  }
  return {...out, ...extras};
}

/// Transcript + summary for one take.
class TakeNotes {
  TakeNotes({
    required this.path,
    required this.language,
    required this.duration,
    required this.segments,
    this.summary,
    this.template = 'meeting',
    this.engine = '',
  });

  final String path;
  final String language;
  final double duration;
  final List<NoteSegment> segments;
  Map<String, dynamic>? summary;
  String template;
  String engine;

  String get text => segments.map((s) => s.text).join(' ');

  bool get hasTranscript => segments.isNotEmpty;

  /// True when a summary with at least one bullet is present.
  bool get hasSummary => summary != null && summarySections.any((s) => s.value.isNotEmpty);

  static TakeNotes fromJson(String path, Map<String, dynamic> json) => TakeNotes(
        path: path,
        language: (json['language'] ?? '') as String,
        duration: ((json['duration'] ?? 0) as num).toDouble(),
        engine: (json['engine'] ?? '') as String,
        template: (json['template'] ?? 'meeting') as String,
        summary: (json['summary'] as Map?)?.cast<String, dynamic>(),
        segments: [
          for (final s in (json['segments'] as List? ?? const []))
            NoteSegment(
              ((s['start'] ?? 0) as num).toDouble(),
              ((s['end'] ?? 0) as num).toDouble(),
              (s['text'] ?? '') as String,
              s['speaker'] as String?,
            ),
        ],
      );

  Map<String, dynamic> toJson() => {
        'version': 1,
        'language': language,
        'duration': duration,
        'engine': engine,
        'template': template,
        'summary': summary,
        'segments': [
          for (final s in segments)
            {
              'start': s.start,
              'end': s.end,
              'text': s.text,
              if (s.speaker != null) 'speaker': s.speaker,
            }
        ],
      };

  Map<String, dynamic> get transcriptJson => {
        'source': path,
        'language': language,
        'duration': duration,
        'engine': engine,
        'segments': [
          for (final s in segments)
            {'start': s.start, 'end': s.end, 'text': s.text, if (s.speaker != null) 'speaker': s.speaker}
        ],
      };

  /// Summary sections in template order, with bullets trimmed. Works for old
  /// sidecars too, so previously inconsistent output renders consistently.
  List<MapEntry<String, List<String>>> get summarySections {
    final raw = (summary?['sections'] as Map?) ?? const {};
    final normal = normaliseSections(raw, template);
    return [for (final e in normal.entries) MapEntry(e.key, e.value)];
  }
}

/// Result of the work already done for a take, plus the template now selected.
/// Used so opening a take again never re-runs a job that already has a result.
enum NotesAction {
  /// Nothing on disk for this take: transcribe, then summarise.
  transcribeAndSummarize,

  /// A transcript exists but no summary for the selected template: summarise only.
  summarizeOnly,

  /// Transcript and summary are both present for this template: do nothing.
  none,
}

NotesAction notesAction({
  TakeNotes? notes,
  required String template,
  bool force = false,
}) {
  if (force) return NotesAction.transcribeAndSummarize;
  if (notes == null || !notes.hasTranscript) return NotesAction.transcribeAndSummarize;
  if (notes.hasSummary && notes.template == template) return NotesAction.none;
  return NotesAction.summarizeOnly;
}

class NoteSegment {
  NoteSegment(this.start, this.end, this.text, [this.speaker]);
  final double start;
  final double end;
  final String text;
  final String? speaker;

  /// True when at least one segment carries a diarization label.
  static bool anyLabelled(List<NoteSegment> segments) =>
      segments.any((s) => s.speaker != null);

  String get stamp {
    final s = start.round();
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
