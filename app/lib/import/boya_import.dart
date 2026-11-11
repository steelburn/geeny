import 'dart:convert';

import '../ai/notes.dart';

/// A transcript and/or summary read out of a file exported by Boya OS.
///
/// Boya OS has no import API — its recordings live in its cloud — but its Export
/// menu writes TXT, Markdown, SRT, DOCX and PDF, and its Share button hands a file
/// to other apps. TXT/Markdown/SRT and JSON are read here; DOCX and PDF are not
/// (export as TXT or Markdown instead). Nothing about this needs an account.
class ImportedNote {
  ImportedNote({
    this.title = '',
    this.language = '',
    this.duration = 0,
    this.template = 'meeting',
    this.engine = 'imported · Boya OS export',
    List<NoteSegment>? segments,
    Map<String, List<String>>? sections,
  })  : segments = segments ?? [],
        sections = sections ?? {};

  String title;
  String language;
  double duration;
  String template;
  String engine;
  final List<NoteSegment> segments;
  final Map<String, List<String>> sections;

  bool get hasTranscript => segments.any((s) => s.text.trim().isNotEmpty);
  bool get hasSummary => sections.values.any((v) => v.isNotEmpty);
  bool get isEmpty => !hasTranscript && !hasSummary;

  /// Notes in the app's own sidecar shape, ready to write beside a take.
  TakeNotes toNotes(String path) => TakeNotes(
        path: path,
        language: language,
        duration: duration,
        segments: [
          for (final s in segments)
            if (s.text.trim().isNotEmpty) s,
        ],
        template: template,
        engine: engine,
        summary: hasSummary
            ? {
                'template': template,
                'engine': engine,
                'sections': {
                  for (final e in sections.entries)
                    if (e.value.isNotEmpty) e.key: e.value,
                },
              }
            : null,
      );
}

// --- naming ----------------------------------------------------------------

/// Words Boya OS (and a file manager) put after a name: what the file holds, or
/// that it is a second copy.
const _suffixWords = [
  'recording',
  'record',
  'audio',
  'transcript',
  'transcription',
  'summary',
  'notes',
  'note',
  'copy',
];

final _kindSuffix = RegExp(
  r'[\s._\-–—]*[\(\[]?\s*(?:' + _suffixWords.join('|') + r')\s*[\)\]]?\s*$',
  caseSensitive: false,
);

/// Geeny's own decoration on a stored import: `boya-<name>-2026-11-11T0908.mp3`
/// and `imported-<name>-2026-11-11T0908.ogg`.
final _storedPrefix = RegExp(r'^(?:boya|imported)-', caseSensitive: false);
final _storedStamp = RegExp(r'-\d{4}-\d{2}-\d{2}T\d{4,6}$');

/// A copy marker the system adds to a second export of the same name: `(1)`.
final _copyMarker = RegExp(r'[\s._\-–—]*[\(\[]\s*\d{1,3}\s*[\)\]]\s*$');

/// The key that three exports of one meeting share.
///
/// Boya OS names every export after the recording and puts the kind in a suffix:
/// `Sampling walk (Recording).ogg`, `Sampling walk (Transcript).txt`,
/// `Sampling walk - Summary.md`. The extension differs as well, and Geeny stores
/// an import under its own `boya-…`/`imported-…` name with a timestamp. All of
/// that is stripped here, so a recording and its transcript compare equal and
/// the import can attach one to the other instead of making a second take.
///
/// The result is lower case with runs of punctuation folded to single spaces.
/// An empty result means the name carried nothing but a kind word (`Recording`,
/// `Transcript`): it is never used for matching, so two such files are not
/// forced into one group without a name to go on.
String exportGroupKey(String fileName) {
  final base = _withoutExtension(fileName.split(RegExp(r'[\\/]')).last);
  var key = base.replaceFirst(_storedPrefix, '').replaceFirst(_storedStamp, '');
  // A name can carry more than one suffix (`… transcript (1)`, `… summary copy`).
  var previous = '';
  while (key != previous) {
    previous = key;
    key = key.replaceFirst(_copyMarker, '');
    key = key.replaceFirst(_kindSuffix, '');
  }
  return _slug(key);
}

String _slug(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

String _withoutExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Read an export by extension, falling back to sniffing the content.
ImportedNote? parseExport(String content, {String sourceName = ''}) {
  final text = content.replaceFirst('\uFEFF', '').trim();
  if (text.isEmpty) return null;
  final fallbackTitle = _titleFromName(sourceName);

  final trimmed = text.trimLeft();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      final json = jsonDecode(text);
      final note = parseJsonExport(json, fallbackTitle);
      if (note != null && !note.isEmpty) return note;
    } catch (_) {
      // not JSON after all — fall through to the text readers
    }
  }
  if (_srtTime.hasMatch(text)) {
    final note = parseSrt(text);
    if (!note.isEmpty) {
      if (note.title.isEmpty) note.title = fallbackTitle;
      return note;
    }
  }
  final note = parseTextExport(text, fallbackTitle);
  return note.isEmpty ? null : note;
}

// --- SRT --------------------------------------------------------------------

final _srtTime = RegExp(
  r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})',
);

ImportedNote parseSrt(String content) {
  final note = ImportedNote(engine: 'imported · SRT');
  final blocks = content.replaceAll('\r\n', '\n').split(RegExp(r'\n{2,}'));
  for (final block in blocks) {
    final match = _srtTime.firstMatch(block);
    if (match == null) continue;
    final lines = block.split('\n');
    final timeIndex = lines.indexWhere((l) => _srtTime.hasMatch(l));
    final body = lines.skip(timeIndex + 1).join(' ').replaceAll(RegExp(r'<[^>]+>'), '').trim();
    if (body.isEmpty) continue;
    note.segments.add(NoteSegment(
      _secondsOf(match.group(1)!, match.group(2)!, match.group(3)!, match.group(4)!),
      _secondsOf(match.group(5)!, match.group(6)!, match.group(7)!, match.group(8)!),
      body,
    ));
  }
  if (note.segments.isNotEmpty) {
    note.duration = note.segments.last.end;
    note.language = '';
  }
  return note;
}

double _secondsOf(String h, String m, String s, String ms) =>
    int.parse(h) * 3600 + int.parse(m) * 60 + int.parse(s) + int.parse(ms.padRight(3, '0')) / 1000;

/// `05:48`, `00:05:48`, `72` or `72.5` -> seconds.
double? _seconds(dynamic value) {
  if (value is num) return value.toDouble();
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return null;
  final clock = RegExp(r'^(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?$').firstMatch(raw);
  if (clock != null) {
    final h = int.tryParse(clock.group(1) ?? '0') ?? 0;
    final m = int.parse(clock.group(2)!);
    final s = int.parse(clock.group(3)!);
    final frac = clock.group(4) == null ? 0.0 : int.parse(clock.group(4)!.padRight(3, '0')) / 1000;
    return h * 3600 + m * 60 + s + frac;
  }
  return double.tryParse(raw);
}

// --- JSON -------------------------------------------------------------------

ImportedNote? parseJsonExport(dynamic json, String fallbackTitle) {
  if (json is List) {
    final segments = _segmentsFrom(json);
    if (segments == null || segments.isEmpty) return null;
    return ImportedNote(title: fallbackTitle, segments: segments, engine: 'imported · JSON');
  }
  if (json is! Map) return null;
  final map = json.cast<String, dynamic>();
  final title = _firstString(map, ['title', 'name', 'fileName', 'file_name', 'recordName']) ??
      fallbackTitle;
  final language = _firstString(map, ['language', 'lang', 'languageCode']) ?? '';
  final engine = _firstString(map, ['engine']) ?? 'imported · JSON';
  final template = _firstString(map, ['template']) ?? 'meeting';

  final segments = _segmentsFrom(map['segments'] ?? map['transcript'] ?? map['lines']) ??
      _segmentsFrom(_findSegmentList(json) ?? const []) ??
      const <NoteSegment>[];

  final sections = _sectionsFrom(map['summary'] ?? map['sections']) ??
      (() {
        final text = _firstString(map, ['summaryText']);
        return text == null ? null : {'Overview': [text]};
      })();

  final duration = _seconds(map['duration']) ?? (segments.isEmpty ? 0 : segments.last.end);
  final note = ImportedNote(
    title: title,
    language: language,
    duration: duration,
    template: template,
    engine: engine,
    segments: segments,
    sections: sections ?? {},
  );
  return note.isEmpty ? null : note;
}

List<NoteSegment>? _segmentsFrom(dynamic value) {
  if (value is String) {
    final text = value.trim();
    return text.isEmpty ? null : [NoteSegment(0, 0, text)];
  }
  if (value is! List) return null;
  final out = <NoteSegment>[];
  for (var i = 0; i < value.length; i++) {
    final item = value[i];
    if (item is String) {
      if (item.trim().isNotEmpty) out.add(NoteSegment(0, 0, item.trim()));
      continue;
    }
    if (item is! Map) continue;
    final text = _firstString(item.cast<String, dynamic>(),
        ['text', 'content', 'sentence', 'transcript', 'words']);
    if (text == null || text.trim().isEmpty) continue;
    final start = _seconds(item['start'] ?? item['startTime'] ?? item['begin']) ?? 0;
    final end = _seconds(item['end'] ?? item['endTime'] ?? item['stop']) ?? start;
    out.add(NoteSegment(start, end, text.trim(), item['speaker']?.toString()));
  }
  return out.isEmpty ? null : out;
}

/// Depth-limited hunt for a list of objects that look like transcript segments.
List<Map<dynamic, dynamic>>? _findSegmentList(dynamic node, [int depth = 0]) {
  if (depth > 4) return null;
  if (node is List) {
    final maps = node.whereType<Map>().toList();
    if (maps.length >= 2 && maps.every((m) => m['text'] != null || m['content'] != null)) {
      return maps;
    }
    for (final item in node) {
      final found = _findSegmentList(item, depth + 1);
      if (found != null) return found;
    }
    return null;
  }
  if (node is Map) {
    for (final value in node.values) {
      final found = _findSegmentList(value, depth + 1);
      if (found != null) return found;
    }
  }
  return null;
}

Map<String, List<String>>? _sectionsFrom(dynamic value) {
  if (value is String) {
    final text = value.trim();
    return text.isEmpty ? null : {'Overview': [text]};
  }
  if (value is! Map) return null;
  final raw = value['sections'] is Map ? value['sections'] as Map : value;
  final out = <String, List<String>>{};
  for (final entry in raw.entries) {
    final bullets = <String>[];
    final v = entry.value;
    if (v is Iterable) {
      for (final item in v) {
        final text = item.toString().trim();
        if (text.isNotEmpty) bullets.add(text);
      }
    } else if (v != null) {
      final text = v.toString().trim();
      if (text.isNotEmpty) bullets.add(text);
    }
    if (bullets.isNotEmpty) out[entry.key.toString()] = bullets;
  }
  return out.isEmpty ? null : out;
}

String? _firstString(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

// --- TXT / Markdown ---------------------------------------------------------

/// `[00:12] text`, `- \`00:12\` text`, `00:12 - text`, `(00:12) text`.
final _stamped = RegExp(
  r'^\s*(?:[-*•]\s*)?[\[\(`]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\]\)`]?\s*[-–:·]?\s*(.+)$',
);

ImportedNote parseTextExport(String content, String fallbackTitle) {
  final note = ImportedNote(engine: 'imported · text');
  final lines = content.replaceAll('\r\n', '\n').split('\n');
  var title = fallbackTitle;
  final sections = <String, List<String>>{};
  String? heading;
  final transcript = <NoteSegment>[];
  final plain = <String>[];

  bool inTranscript = false;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    if (trimmed.startsWith('# ')) {
      if (title == fallbackTitle || title.isEmpty) title = trimmed.substring(2).trim();
      continue;
    }
    if (trimmed.startsWith('## ') || trimmed.startsWith('### ')) {
      heading = trimmed.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      inTranscript = heading.toLowerCase() == 'transcript';
      if (!inTranscript && !sections.containsKey(heading)) sections[heading] = [];
      continue;
    }
    if (inTranscript) {
      final stamped = _stamped.firstMatch(trimmed);
      final body = stamped?.group(2)?.trim() ?? trimmed.replaceFirst(RegExp(r'^[-*•]\s*'), '').trim();
      if (body.isEmpty) continue;
      transcript.add(NoteSegment(_seconds(stamped?.group(1)) ?? 0, 0, body));
      continue;
    }
    if (heading != null) {
      final bullet = trimmed.replaceFirst(RegExp(r'^[-*•]+\s*'), '').trim();
      if (bullet.isNotEmpty) sections[heading]!.add(bullet);
      continue;
    }
    final stamped = _stamped.firstMatch(trimmed);
    if (stamped != null && _seconds(stamped.group(1)) != null) {
      transcript.add(NoteSegment(_seconds(stamped.group(1))!, 0, stamped.group(2)!.trim()));
    } else {
      plain.add(trimmed);
    }
  }

  // A file with no headings at all is still a transcript.
  if (transcript.isEmpty && plain.isNotEmpty) {
    transcript.add(NoteSegment(0, 0, plain.join(' ')));
  }
  if (sections.isEmpty && plain.isNotEmpty && transcript.isNotEmpty) {
    // Nothing to do: the body was a transcript, not a summary.
  }
  note.segments.addAll(transcript);
  note.sections.addAll(sections);
  note.title = title;
  if (note.segments.isNotEmpty) note.duration = note.segments.last.end;
  return note;
}

String _titleFromName(String name) =>
    _withoutExtension(name.split(RegExp(r'[\\/]')).last).trim();
