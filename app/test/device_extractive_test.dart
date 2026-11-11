import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/device/extractive.dart';

Map<String, dynamic> transcript(List<String> lines, {String language = 'en'}) => {
      'language': language,
      'duration': lines.length * 4,
      'segments': [
        for (var i = 0; i < lines.length; i++)
          {'start': i * 4, 'end': i * 4 + 4, 'text': lines[i]},
      ],
    };

void main() {
  test('a meeting summary has the template headings in order', () {
    final summary = extractiveSummary(
      transcript([
        'The sampling plan is the main thing we discussed today.',
        'We need to finish the sampling plan before Friday.',
        'The budget review is scheduled for next month.',
        'Nobody disagreed with the sampling plan.',
      ]),
      'meeting',
    );

    expect(summary['template'], 'meeting');
    expect(summary['engine'], 'extractive · on device');
    final sections = summary['sections'] as Map<String, List<String>>;
    expect(sections.keys.toList(), ['Overview', 'Decisions & actions', 'Key points']);
  });

  test('sentences are picked from the transcript, never invented', () {
    final lines = [
      'Quarterly numbers came in above the plan we set.',
      'The team will move the release to March.',
      'Support tickets dropped after the docs rewrite.',
    ];
    final summary = extractiveSummary(transcript(lines), 'meeting');
    final bullets = (summary['sections'] as Map<String, List<String>>)
        .values
        .expand((v) => v)
        .toList();
    expect(bullets, isNotEmpty);
    for (final bullet in bullets) {
      expect(lines, contains(bullet));
    }
  });

  test('an action sentence lands under Decisions & actions', () {
    final summary = extractiveSummary(
      transcript([
        'We reviewed the field data from the northern plot.',
        'The northern plot data needs a second review.',
        'Field data from the northern plot was archived.',
        'The northern plot is the one we care about.',
        'We will order more filters.',
      ]),
      'meeting',
    );
    final actions =
        (summary['sections'] as Map<String, List<String>>)['Decisions & actions']!;
    expect(actions, isNotEmpty);
    expect(actions.any((a) => a.contains('filters')), isTrue);
  });

  test('a lecture summary uses its own headings', () {
    final summary = extractiveSummary(
      transcript([
        'Photosynthesis turns light into chemical energy.',
        'Chlorophyll absorbs mostly red and blue light.',
        'The Calvin cycle fixes carbon into sugar.',
        'Review the light reactions before the lab.',
        'The reading covers both stages of the process.',
      ]),
      'lecture',
    );
    final sections = summary['sections'] as Map<String, List<String>>;
    expect(sections.keys.toList(), ['Overview', 'Key concepts', 'To review']);
    expect(sections['To review'], isEmpty);
  });

  test('an unknown template falls back to plain, not to an empty summary', () {
    final summary = extractiveSummary(
      transcript(['One sentence is enough to summarise this short note.']),
      'podcast',
    );
    expect(summary['template'], 'plain');
    expect((summary['sections'] as Map<String, List<String>>).keys.toList(),
        ['Overview', 'Key points']);
  });

  test('an empty transcript summarises to nothing rather than throwing', () {
    final summary = extractiveSummary({'segments': const []}, 'meeting');
    expect(summary['sections'], isEmpty);
  });

  test('a transcript with no sentence punctuation still yields bullets', () {
    final summary = extractiveSummary(
      transcript(['the plan needs a second review before the deadline']),
      'meeting',
    );
    final bullets = (summary['sections'] as Map<String, List<String>>)
        .values
        .expand((v) => v)
        .toList();
    expect(bullets, isNotEmpty);
  });

  test('a non-Latin transcript is scored by its own words', () {
    final summary = extractiveSummary(
      transcript([
        '今日はサンプリング計画について話しました。',
        'サンプリング計画は金曜日までに終わらせます。',
        '予算の見直しは来月です。',
        'サンプリング計画に反対はありませんでした。',
      ], language: 'ja'),
      'meeting',
    );
    final bullets = (summary['sections'] as Map<String, List<String>>)
        .values
        .expand((v) => v)
        .toList();
    expect(bullets.length, greaterThan(1));
    expect(bullets.join(' '), contains('サンプリング計画'));
  });
}
