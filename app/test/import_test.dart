import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/import/boya_import.dart';

void main() {
  test('an SRT export becomes timestamped segments', () {
    const srt = '''
1
00:00:00,000 --> 00:00:04,120
We agreed the sampling grid starts at the north fence.

2
00:00:04,120 --> 00:00:09,500
Ali orders the sample bags by Friday.
''';
    final note = parseExport(srt, sourceName: 'Field notes.srt')!;
    expect(note.segments.length, 2);
    expect(note.segments.first.start, 0);
    expect(note.segments.last.start, closeTo(4.12, 0.001));
    expect(note.segments.last.text, 'Ali orders the sample bags by Friday.');
    expect(note.duration, closeTo(9.5, 0.001));
    expect(note.title, 'Field notes');
  });

  test('a Geeny-style markdown export keeps summary and transcript apart', () {
    const md = '''
# Budget review

_48s · en · extractive summary_

## Summary
Overview:
• The recorder budget is over by four percent.

## Transcript
- `00:00` The recorder budget is over by four percent.
- `00:08` We move the purchase to next quarter.
''';
    final note = parseExport(md, sourceName: 'export.md')!;
    expect(note.title, 'Budget review');
    expect(note.sections['Summary'], ['Overview:', 'The recorder budget is over by four percent.']);
    expect(note.segments.length, 2);
    expect(note.segments.last.stamp, '00:08');
    expect(note.toNotes('/tmp/x.ogg').hasTranscript, isTrue);
  });

  test('a plain Boya TXT export with leading timestamps is a transcript', () {
    const txt = '''
00:05 - Welcome to the lecture on entropy.
01:12 - Entropy counts the number of microstates.
''';
    final note = parseExport(txt, sourceName: 'Lecture.txt')!;
    expect(note.segments.length, 2);
    expect(note.segments.first.start, 5);
    expect(note.segments.last.text, 'Entropy counts the number of microstates.');
  });

  test('a JSON transcript with segments is read as-is', () {
    final json = jsonEncode({
      'title': 'Standup',
      'language': 'en',
      'duration': 30,
      'segments': [
        {'start': 0, 'end': 3, 'text': 'First item.', 'speaker': 'Speaker 1'},
        {'start': 3, 'end': 6, 'text': 'Second item.', 'speaker': 'Speaker 2'},
      ],
      'summary': {
        'sections': {
          'Overview': ['Two items.'],
        },
      },
    });
    final note = parseExport(json, sourceName: 'standup.json')!;
    expect(note.title, 'Standup');
    expect(note.segments.length, 2);
    expect(note.segments.last.speaker, 'Speaker 2');
    expect(note.sections['Overview'], ['Two items.']);
    expect(note.hasSummary, isTrue);
  });

  test('a JSON export with only a summary still imports', () {
    final json = jsonEncode({
      'title': 'Recap',
      'summary': 'The project is on track.',
    });
    final note = parseExport(json, sourceName: 'recap.json')!;
    expect(note.hasTranscript, isFalse);
    expect(note.sections['Overview'], ['The project is on track.']);
  });

  test('an unreadable file imports nothing rather than guessing', () {
    expect(parseExport('   ', sourceName: 'empty.txt'), isNull);
    expect(parseExport('%PDF-1.4 binary soup', sourceName: 'x.txt')?.segments.length, 1,
        reason: 'a text file with no timestamps is still a transcript');
  });

  test('a notes-only import has no audio and says so', () {
    final note = parseExport('00:01 - one line', sourceName: 'x.txt')!;
    final notes = note.toNotes('/docs/imported-x.ogg');
    expect(notes.language, '');
    expect(notes.engine, 'imported · text');
    expect(notes.summary, isNull);
    expect(notes.segments.single.text, 'one line');
  });
}
