/// Search results and answers from the local index.
///
/// Search reads what the takes already have — transcript segments and summary
/// bullets — so a hit always points at a take and, when it came from the
/// transcript, at a moment in it.
library;

class AskHit {
  AskHit({
    required this.id,
    required this.title,
    required this.text,
    this.date = '',
    this.project = '',
    this.section = '',
    this.start,
    this.score = 0,
    this.cited = false,
  });

  /// Take path, exactly as the app sent it when it built the index.
  final String id;
  final String title;
  final String text;
  final String date;
  final String project;
  final String section;

  /// Seconds into the take; null when the passage is a summary section.
  final double? start;
  final double score;

  /// True when the answer cited this source (`[n]` in the answer text).
  bool cited;

  static AskHit fromJson(Map<String, dynamic> json) => AskHit(
        id: (json['id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        text: (json['text'] ?? '').toString(),
        date: (json['date'] ?? '').toString(),
        project: (json['project'] ?? '').toString(),
        section: (json['section'] ?? '').toString(),
        start: (json['start'] as num?)?.toDouble(),
        score: (json['score'] as num?)?.toDouble() ?? 0,
        cited: json['cited'] == true,
      );

  /// `05:48` for a transcript line, `sum` for a summary passage.
  String get stamp {
    final at = start;
    if (at == null) return 'sum';
    final seconds = at.round();
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }

  /// The line under a result title: when, which project, which summary section.
  String get where {
    final parts = <String>[
      if (date.isNotEmpty) date,
      if (project.isNotEmpty) project,
      if (start == null && section.isNotEmpty) section,
    ];
    return parts.join(' · ');
  }
}

class AskAnswer {
  AskAnswer({
    required this.answer,
    required this.engine,
    required this.sources,
  });

  final String answer;
  final String engine;
  final List<AskHit> sources;

  /// True when no model wrote it: the passages themselves are the answer.
  bool get extractive => engine.startsWith('extractive');

  static AskAnswer fromJson(Map<String, dynamic> json) => AskAnswer(
        answer: (json['answer'] ?? '').toString().trim(),
        engine: (json['engine'] ?? '').toString(),
        sources: [
          for (final s in (json['sources'] as List? ?? const []))
            if (s is Map) AskHit.fromJson(s.cast<String, dynamic>()),
        ],
      );
}
