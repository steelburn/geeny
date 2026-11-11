import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/notes.dart';
import 'package:geeny_app/state/takes.dart';

Take take(String name) => Take(
      file: File('/tmp/$name'),
      bytes: 1024,
      modified: DateTime(2026, 11, 11),
    );

void main() {
  final a = take('a.ogg');
  final b = take('b.ogg');
  final c = take('c.ogg');
  final items = [a, b, c];
  final projects = {a.file.path: 'Sampling', b.file.path: 'Work'};

  test('all returns everything', () {
    expect(filterTakes(items, projects, 'all'), items);
  });

  test('unfiled returns only takes without a project', () {
    expect(filterTakes(items, projects, 'unfiled'), [c]);
  });

  test('a project returns only its takes', () {
    expect(filterTakes(items, projects, 'Sampling'), [a]);
    expect(filterTakes(items, projects, 'Missing'), isEmpty);
  });

  group('an import already in the library', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('geeny_import_'));
    tearDown(() => dir.deleteSync(recursive: true));

    Take takeOf(String name, List<int> bytes) {
      final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
      return Take(
        file: file,
        bytes: bytes.length,
        modified: DateTime(2026, 11, 11),
      );
    }

    test('is found by its bytes, not by the name it was stored under', () {
      // The share was `Field notes.mp3`; the library keeps it as `boya-…`.
      final stored = takeOf('boya-Field notes-2026-11-11T0908.mp3', [1, 2, 3, 4, 5]);
      final shared = File('${dir.path}/Field notes.mp3')..writeAsBytesSync([1, 2, 3, 4, 5]);

      expect(Take.findByContent([stored], shared), same(stored));
    });

    test('a different recording of the same size is imported, not skipped', () {
      final stored = takeOf('boya-One-2026-11-11T0908.mp3', [1, 2, 3, 4, 5]);
      final shared = File('${dir.path}/Two.mp3')..writeAsBytesSync([1, 2, 3, 9, 5]);

      expect(Take.findByContent([stored], shared), isNull);
    });

    test('a transcript-only take is never the duplicate', () {
      final notesOnly = Take(
        file: File('${dir.path}/imported-recap.ogg'),
        bytes: 0,
        modified: DateTime(2026, 11, 11),
        hasAudio: false,
      );
      final shared = File('${dir.path}/empty.ogg')..writeAsBytesSync(const []);

      expect(Take.findByContent([notesOnly], shared), isNull);
    });

    test('a share that is gone is not a duplicate', () {
      final stored = takeOf('boya-One.mp3', [1, 2, 3]);
      expect(Take.findByContent([stored], File('${dir.path}/missing.mp3')), isNull);
    });
  });

  group('what a take brings to a group', () {
    TakeNotes withNotes({List<NoteSegment>? segments, Map<String, dynamic>? summary}) =>
        TakeNotes(
          path: '/tmp/x.ogg',
          language: 'en',
          duration: 3,
          segments: segments ?? const [],
          summary: summary,
        );

    test('audio is the recording, whatever notes it also has', () {
      expect(kindOfTake(hasAudio: true, notes: withNotes()), TakeKind.recording);
      expect(
        kindOfTake(hasAudio: true, notes: withNotes(segments: [NoteSegment(0, 1, 'hi')])),
        TakeKind.recording,
      );
    });

    test('an import without audio is the words it holds', () {
      expect(kindOfTake(hasAudio: false, notes: withNotes()), TakeKind.empty);
      expect(
        kindOfTake(hasAudio: false, notes: withNotes(segments: [NoteSegment(0, 1, 'hi')])),
        TakeKind.transcript,
      );
      expect(
        kindOfTake(
          hasAudio: false,
          notes: withNotes(summary: {
            'sections': {
              'Overview': ['A bullet.'],
            },
          }),
        ),
        TakeKind.summary,
      );
    });

    test('a transcript that carries a summary counts as the transcript', () {
      expect(
        kindOfTake(
          hasAudio: false,
          notes: withNotes(
            segments: [NoteSegment(0, 1, 'hi')],
            summary: {
              'sections': {
                'Overview': ['A bullet.'],
              },
            },
          ),
        ),
        TakeKind.transcript,
      );
    });
  });
}
