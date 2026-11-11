import 'package:flutter_test/flutter_test.dart';
import 'package:notra_app/ai/ai_settings.dart';
import 'package:notra_app/ai/notes.dart';

TakeNotes notes({
  String template = 'meeting',
  Map<String, dynamic>? summary,
  List<NoteSegment>? segments,
}) =>
    TakeNotes(
      path: '/tmp/take.ogg',
      language: 'en',
      duration: 12,
      template: template,
      summary: summary,
      segments: segments ?? [NoteSegment(0, 4, 'A real sentence from the take.')],
    );

final meetingSummary = {
  'template': 'meeting',
  'engine': 'extractive',
  'sections': {
    'Overview': ['A real sentence from the take.'],
  },
};

void main() {
  test('a take without notes needs transcription, then a summary', () {
    expect(notesAction(notes: null, template: 'meeting'),
        NotesAction.transcribeAndSummarize);
    expect(
      notesAction(
        notes: notes(segments: []),
        template: 'meeting',
      ),
      NotesAction.transcribeAndSummarize,
    );
  });

  test('an existing transcript is reused; only the summary is missing', () {
    expect(notesAction(notes: notes(), template: 'meeting'), NotesAction.summarizeOnly);
  });

  test('an existing transcript + summary for the same template runs nothing', () {
    expect(
      notesAction(notes: notes(summary: meetingSummary), template: 'meeting'),
      NotesAction.none,
    );
  });

  test('switching template re-summarises, never re-transcribes', () {
    expect(
      notesAction(notes: notes(summary: meetingSummary), template: 'lecture'),
      NotesAction.summarizeOnly,
    );
  });

  test('force (the Redo button) repeats both steps', () {
    expect(
      notesAction(notes: notes(summary: meetingSummary), template: 'meeting', force: true),
      NotesAction.transcribeAndSummarize,
    );
  });

  test('gguf names are shortened for labels', () {
    expect(AiSettings.shortModelName('qwen2.5-1.5b-instruct-q4_k_m'), 'qwen2.5-1.5b');
    expect(AiSettings.shortModelName('qwen2.5-3b-instruct-q4_k_m'), 'qwen2.5-3b');
    expect(AiSettings.shortModelName('llama-3.2-3b-instruct-q4_k_m'), 'llama-3.2-3b');
  });

  test('model output is normalised to the template order and headings', () {
    final result = normaliseSections({
      'Key Points': ['- point one', '2. point two'],
      'summary': 'This is the overview.',
      'Actions': ['ship it'],
      'Something Else': ['kept'],
    }, 'meeting');

    expect(result.keys.toList(),
        ['Overview', 'Decisions & actions', 'Key points', 'Something Else']);
    expect(result['Overview'], ['This is the overview.']);
    expect(result['Decisions & actions'], ['ship it']);
    expect(result['Key points'], ['point one', 'point two']);
    expect(result['Something Else'], ['kept']);
  });

  test('lecture sections stay in their own order', () {
    final result = normaliseSections({
      'To Review': ['reread chapter 2'],
      'key ideas': ['entropy'],
      'Overview': ['a lecture'],
    }, 'lecture');
    expect(result.keys.toList(), ['Overview', 'Key concepts', 'To review']);
    expect(result['Key concepts'], ['entropy']);
    expect(result['To review'], ['reread chapter 2']);
  });

  test('old sidecars render in template order too', () {
    final stored = TakeNotes(
      path: '/tmp/take.ogg',
      language: 'en',
      duration: 1,
      segments: [NoteSegment(0, 1, 'hello')],
      summary: {
        'sections': {
          'Key points': ['b'],
          'Overview': ['a'],
        }
      },
    );
    expect(stored.summarySections.map((e) => e.key).toList(),
        ['Overview', 'Decisions & actions', 'Key points']);
    expect(stored.summarySections.first.value, ['a']);
  });

  test('notes round-trip through JSON so they survive a restart', () {
    final original = notes(summary: meetingSummary)
      ..engine = 'local · whisper small'
      ..segments[0] = NoteSegment(0, 4, 'A real sentence from the take.', 'Speaker 1');

    final restored = TakeNotes.fromJson(original.path, original.toJson());

    expect(restored.language, original.language);
    expect(restored.duration, original.duration);
    expect(restored.engine, original.engine);
    expect(restored.template, original.template);
    expect(restored.segments.single.speaker, 'Speaker 1');
    final overview = restored.summarySections.firstWhere((e) => e.key == 'Overview');
    expect(overview.value, ['A real sentence from the take.']);
    expect(notesAction(notes: restored, template: 'meeting'), NotesAction.none);
  });
}
