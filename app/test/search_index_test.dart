import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/ask.dart';
import 'package:geeny_app/ai/search_index.dart';

Map<String, dynamic> doc(
  String id,
  String title,
  String date,
  List<Map<String, dynamic>> segments, {
  Map<String, List<String>> summary = const {},
  String project = '',
}) =>
    {
      'id': id,
      'title': title,
      'date': date,
      'project': project,
      'duration': 60,
      'segments': segments,
      'summary': {'sections': summary},
    };

final library = [
  doc('a.ogg', 'Sampling plan', '11 Nov · 05:48', [
    {'start': 0, 'end': 6, 'text': 'We looked at the soil sampling grid for the north field.'},
    {'start': 6, 'end': 14, 'text': 'The lab will need twelve cores per hectare.'},
    {'start': 14, 'end': 22, 'text': 'Ali will order the bags by Friday.'},
  ], summary: {
    'Overview': ['Plan for soil sampling in the north field.'],
    'Decisions & actions': ['Ali orders sample bags by Friday.'],
  }, project: 'Sampling'),
  doc('b.ogg', 'Budget review', '12 Nov · 09:10', [
    {'start': 0, 'end': 8, 'text': 'The recorder budget is over by four percent.'},
    {'start': 8, 'end': 15, 'text': 'We agreed to move the purchase to next quarter.'},
  ], summary: {
    'Overview': ['Recorder budget is over.'],
  }, project: 'Work'),
  doc('c.ogg', 'Lecture on entropy', '12 Nov · 14:00', [
    {'start': 0, 'end': 10, 'text': 'Entropy is a measure of the number of microstates.'},
  ], summary: {
    'Key concepts': ['Entropy counts microstates.'],
  }),
];

SearchIndex build() => SearchIndex()..replace(library);

void main() {
  group('tokenising', () {
    test('words are lowercased', () {
      expect(tokenize('Sampling Plan'), ['sampling', 'plan']);
    });

    test('CJK gets character bigrams', () {
      final tokens = tokenize('会议纪要');
      expect(tokens, contains('会议'));
      expect(tokens, contains('纪要'));
    });

    test('question filler is dropped', () {
      expect(queryTerms('What did we decide about the budget?'), ['decide', 'budget']);
    });

    test('a query of nothing but filler still searches', () {
      expect(queryTerms('what about it'), isNotEmpty);
    });
  });

  group('retrieval', () {
    test('the index counts documents and passages', () {
      final index = build();
      expect(index.documentCount, 3);
      expect(index.passageCount, greaterThanOrEqualTo(5));
    });

    test('a query lands on the right take', () {
      final hits = build().search('sampling plan');
      expect(hits, isNotEmpty);
      expect(hits.first.id, 'a.ogg');
    });

    test('a transcript hit carries a timestamp', () {
      final segments = [
        for (var i = 0; i < 10; i++)
          {'start': i * 5, 'end': i * 5 + 5, 'text': 'line $i about nothing much'},
      ];
      final hits = (SearchIndex()
            ..replace([
              doc('long.ogg', 'Ten lines', '13 Nov', segments),
            ]))
          .search('line 9');
      expect(hits.first.id, 'long.ogg');
      // The ninth segment starts a second passage, so the hit lands on it.
      expect(hits.first.start, 40.0);
      expect(hits.first.stamp, '00:40');
    });

    test('a summary passage has no timestamp and names its section', () {
      final hits = build().search('microstates');
      final summary = hits.firstWhere((h) => h.start == null);
      expect(summary.id, 'c.ogg');
      expect(summary.section, 'Key concepts');
      expect(summary.stamp, 'sum');
    });

    test('the project name is searchable', () {
      expect(build().search('sampling').map((h) => h.id), contains('a.ogg'));
    });

    test('the title outranks a passing mention', () {
      expect(build().search('budget').first.id, 'b.ogg');
    });

    test('nonsense matches nothing', () {
      expect(build().search('zzzqqq'), isEmpty);
    });

    test('the limit is respected', () {
      expect(build().search('the', limit: 1).length, 1);
      expect(build().search('sampling', limit: 2).length, lessThanOrEqualTo(2));
    });

    test('a long passage is cut for the row, not the index', () {
      final long = List.generate(
        8,
        (i) => {
          'start': i * 5,
          'end': i * 5 + 5,
          'text': 'word$i ${'filler ' * 30}',
        },
      );
      final hits = (SearchIndex()
            ..replace([
              doc('long.ogg', 'Long', '13 Nov', long),
            ]))
          .search('word3 filler');
      expect(hits, isNotEmpty);
      expect(hits.first.text.endsWith('…'), isTrue);
      expect(hits.first.text.length, lessThanOrEqualTo(281));
    });
  });

  group('passages', () {
    test('a speaker change starts a new passage', () {
      final hits = (SearchIndex()
            ..replace([
              doc('talk.ogg', 'Two voices', '13 Nov', [
                {'start': 0, 'end': 4, 'text': 'the budget is fine', 'speaker': 'Speaker 1'},
                {'start': 4, 'end': 8, 'text': 'agreed, said the auditor', 'speaker': 'Speaker 2'},
              ]),
            ]))
          .search('auditor');
      expect(hits, isNotEmpty);
      expect(hits.first.start, 4.0);
      expect(hits.first.section, 'Speaker 2');
    });

    test('a summary without a transcript is still searchable', () {
      final index = SearchIndex()
        ..replace([
          {
            'id': 'imported.notes.json',
            'title': 'Boya lecture',
            'date': '14 Nov',
            'summary': {
              'sections': {
                'Overview': ['The lecture covered soil compaction.'],
              },
            },
          },
        ]);
      expect(index.documentCount, 1);
      expect(index.search('compaction'), isNotEmpty);
    });

    test('a take with no notes at all is not counted', () {
      final index = SearchIndex()
        ..replace([
          {'id': 'empty.ogg', 'title': 'Empty', 'segments': const [], 'summary': const {}},
        ]);
      expect(index.documentCount, 0);
      expect(index.passageCount, 0);
    });
  });

  group('extractive answer', () {
    test('the passages themselves are the answer, and are cited', () {
      final hits = build().search('sampling plan', limit: 6);
      final answer = extractiveAnswer(hits);
      expect(answer.extractive, isTrue);
      expect(answer.answer, contains('sampling'));
      expect(answer.sources.length, hits.length);
      expect(answer.sources.where((h) => h.cited).length, 3);
      expect(answer.sources.first.cited, isTrue);
      expect(answer.sources.first.id, 'a.ogg');
    });

    test('an excerpt line names the take and the moment', () {
      final hit = AskHit(
        id: 'a.ogg',
        title: 'Sampling plan',
        text: 'we need twelve cores per hectare',
        start: 6,
      );
      expect(hit.excerpt(2),
          '[2] Sampling plan · 00:06 — we need twelve cores per hectare');
      expect(build().search('twelve cores').first.excerpt(1), startsWith('[1] Sampling plan · '));
    });

    test('a summary excerpt names its section instead of a time', () {
      final hit = build().search('microstates').firstWhere((h) => h.start == null);
      expect(hit.excerpt(1), startsWith('[1] Lecture on entropy · Key concepts — '));
    });
  });
}
