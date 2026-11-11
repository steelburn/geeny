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
    expect(restored.summarySections.single.key, 'Overview');
    expect(restored.summarySections.single.value, ['A real sentence from the take.']);
    expect(notesAction(notes: restored, template: 'meeting'), NotesAction.none);
  });
}
