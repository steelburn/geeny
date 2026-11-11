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

  List<MapEntry<String, List<String>>> get summarySections {
    final sections = (summary?['sections'] as Map?) ?? const {};
    return [
      for (final e in sections.entries)
        MapEntry(e.key as String, [for (final b in (e.value as List? ?? const [])) b.toString()])
    ];
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
