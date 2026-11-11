import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/device/segments.dart';

void main() {
  test('token timings become one segment per sentence', () {
    // whisper emits BPE pieces with a leading space, plus specials we ignore.
    final segments = buildSegments(
      tokens: const [
        '<|startoftranscript|>',
        ' We',
        ' need',
        ' to',
        ' move',
        ' the',
        ' release',
        '.',
        ' The',
        ' team',
        ' agreed',
        '.',
      ],
      timestamps: const [0, 0.2, 0.5, 0.8, 1.1, 1.4, 1.7, 2.2, 2.9, 3.3, 3.8, 4.4],
      text: 'We need to move the release. The team agreed.',
      duration: 5,
    );

    expect(segments.length, 2);
    expect(segments[0]['text'], 'We need to move the release.');
    expect(segments[1]['text'], 'The team agreed.');
    expect(segments[0]['start'], lessThan(segments[1]['start'] as double));
    expect(segments[0]['end'], lessThan(4.4));
  });

  test('a long pause starts a new segment even without punctuation', () {
    final segments = buildSegments(
      tokens: const [' hello', ' there', ' again', ' after', ' the', ' break'],
      timestamps: const [0.0, 0.4, 0.8, 6.0, 6.4, 6.8],
      text: 'hello there again after the break',
      duration: 8,
    );
    expect(segments.length, 2);
    expect(segments[0]['text'], 'hello there again');
    expect(segments[1]['text'], 'after the break');
  });

  test('a never-ending sentence is cut at the maximum length', () {
    final tokens = [for (var i = 0; i < 40; i++) ' word$i'];
    final times = [for (var i = 0; i < 40; i++) i * 0.6];
    final segments = buildSegments(
      tokens: tokens,
      timestamps: times,
      text: tokens.join(' ').trim(),
      duration: 30,
      maxSegment: 5,
    );
    expect(segments.length, greaterThan(2));
    for (final s in segments) {
      expect((s['end'] as double) - (s['start'] as double), lessThanOrEqualTo(5.5));
    }
  });

  test('tokens that do not rebuild the text fall back to word timing', () {
    final segments = buildSegments(
      tokens: const ['<|0.00|>', '<|2.00|>'],
      timestamps: const [0, 2],
      text: 'One thing was said. Then another thing was said.',
      duration: 4,
    );
    expect(segments.length, 2);
    expect(segments.first['text'], 'One thing was said.');
    expect(segments.last['text'], 'Then another thing was said.');
    expect(segments.first['start'], 0);
    expect(segments.last['end'], closeTo(4, 0.5));
  });

  test('text without usable timings becomes a single segment', () {
    final segments = buildSegments(
      tokens: const [],
      timestamps: const [],
      text: 'Just one line.',
      duration: 3,
    );
    expect(segments, [
      {'start': 0.0, 'end': 3.0, 'text': 'Just one line.'},
    ]);
  });

  test('no text and no tokens produces no segments', () {
    expect(
      buildSegments(tokens: const [], timestamps: const [], text: '   ', duration: 0),
      isEmpty,
    );
  });

  test('ends never run past the audio duration', () {
    final segments = buildSegments(
      tokens: const [' the', ' end'],
      timestamps: const [9.6, 9.9],
      text: 'the end',
      duration: 10,
    );
    expect((segments.single['end'] as double), lessThanOrEqualTo(10));
  });
}
