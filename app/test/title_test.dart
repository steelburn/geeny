import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/notes.dart';

void main() {
  test('a real title survives as it was written', () {
    expect(cleanTitle('SEER review 11 Nov 2026'), 'SEER review 11 Nov 2026');
    expect(cleanTitle('  Northern plot sampling plan  '), 'Northern plot sampling plan');
    expect(cleanTitle('Tinjauan pelan persampelan'), 'Tinjauan pelan persampelan');
    expect(cleanTitle('采样计划讨论'), '采样计划讨论');
  });

  test('the answers models give when they have no title are rejected', () {
    for (final reply in [
      'null',
      'NULL',
      ' None ',
      'nil',
      'N/A',
      'Untitled',
      'unknown',
      'no title',
      '-',
      '...',
      '…',
      '',
      '   ',
    ]) {
      expect(cleanTitle(reply), isNull, reason: 'reply: "$reply"');
    }
    expect(cleanTitle(null), isNull);
  });

  test('quotes, backticks, emphasis and list markers are stripped', () {
    expect(cleanTitle('"Quarterly budget review"'), 'Quarterly budget review');
    expect(cleanTitle("'Sampling plan'"), 'Sampling plan');
    expect(cleanTitle('`Lab schedule`'), 'Lab schedule');
    expect(cleanTitle('**Sampling plan**'), 'Sampling plan');
    expect(cleanTitle('# Sampling plan'), 'Sampling plan');
    expect(cleanTitle('- Sampling plan'), 'Sampling plan');
    expect(cleanTitle('"Sampling plan."'), 'Sampling plan');
  });

  test('a fenced block or a JSON object is not a title', () {
    expect(cleanTitle('```\nSampling plan\n```'), 'Sampling plan');
    expect(cleanTitle('{"title": "Sampling plan"}'), isNull);
    expect(cleanTitle('["Sampling plan"]'), isNull);
  });

  test('refusals and prose are not titles either', () {
    expect(cleanTitle('As an AI language model, I cannot name this recording.'), isNull);
    expect(cleanTitle('I cannot determine a title from this transcript.'), isNull);
    expect(cleanTitle('Sorry, there is not enough content here.'), isNull);
    expect(
      cleanTitle('The recording begins with a discussion of the sampling plan and the '
          'field data from last quarter, then moves on to the lab schedule and closes '
          'with the budget review that Marta promised to send.'),
      isNull,
      reason: 'a paragraph is prose, not a title',
    );
  });

  test('only the first line is kept, and long titles are trimmed', () {
    expect(cleanTitle('Sampling plan\n\nHere is why I chose it'), 'Sampling plan');
    final long = 'Extraordinarily comprehensive multidisciplinary characterisation '
        'methodology documentation';
    final clean = cleanTitle(long);
    expect(clean, isNotNull);
    expect(clean!.length, lessThanOrEqualTo(81));
    expect(clean.endsWith('…'), isTrue);
  });
}
