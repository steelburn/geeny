import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/ask.dart';

void main() {
  test('a transcript hit shows its timestamp, a summary hit says so', () {
    final line = AskHit.fromJson({
      'id': '/docs/a.ogg',
      'title': 'Sampling plan',
      'text': 'Ali orders the bags.',
      'date': '11 Nov · 05:48',
      'project': 'Sampling',
      'section': 'Transcript',
      'start': 348.4,
      'score': 2.1,
    });
    expect(line.stamp, '05:48');
    expect(line.where, '11 Nov · 05:48 · Sampling');

    final summary = AskHit.fromJson({
      'id': '/docs/a.ogg',
      'title': 'Sampling plan',
      'text': 'Plan.',
      'section': 'Overview',
      'start': null,
    });
    expect(summary.stamp, 'sum');
    expect(summary.where, 'Overview');
  });

  test('an answer carries its sources and which ones were cited', () {
    final answer = AskAnswer.fromJson({
      'answer': 'Ali orders the bags by Friday [1].',
      'engine': 'llama.cpp · qwen2.5-1.5b',
      'sources': [
        {'id': 'a', 'title': 'Sampling plan', 'text': 'x', 'start': 348.0, 'cited': true},
        {'id': 'b', 'title': 'Budget review', 'text': 'y', 'start': null},
      ],
    });
    expect(answer.extractive, isFalse);
    expect(answer.sources.length, 2);
    expect(answer.sources.first.cited, isTrue);
    expect(answer.sources.first.stamp, '05:48');
    expect(answer.sources.last.cited, isFalse);
  });

  test('the extractive engine is recognised so the UI can say so', () {
    final answer = AskAnswer.fromJson({
      'answer': 'passage',
      'engine': 'extractive · matching passages',
      'sources': const [],
    });
    expect(answer.extractive, isTrue);
    expect(answer.sources, isEmpty);
  });
}
