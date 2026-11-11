import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ui/export_audio.dart';

void main() {
  test('a title becomes a file name a person can read', () {
    expect(safeFileName('SEER review 11 Nov 2026'), 'SEER review 11 Nov 2026');
    expect(safeFileName('Tinjauan pelan persampelan'), 'Tinjauan pelan persampelan');
    expect(safeFileName('采样计划讨论'), '采样计划讨论');
  });

  test('path separators and punctuation cannot steer the export', () {
    expect(safeFileName('../../etc/passwd'), 'etcpasswd');
    expect(safeFileName(r'C:\Windows\system32'), 'CWindowssystem32');
    expect(safeFileName('take: 1 / 2 ?'), 'take 1 2');
    expect(safeFileName('emoji 🎙️ take'), 'emoji take');
  });

  test('empty and whitespace-only names fall back, never to a bare extension', () {
    expect(safeFileName(''), 'take');
    expect(safeFileName('   '), 'take');
    expect(safeFileName('🎙️'), 'take');
  });

  test('long names are cut without trailing spaces', () {
    final name = safeFileName('word ' * 40);
    expect(name.length, lessThanOrEqualTo(60));
    expect(name.endsWith(' '), isFalse);
  });

  test('the share sheet gets a mime type that matches the container', () {
    expect(audioMimeFor('/x/take.ogg'), 'audio/ogg');
    expect(audioMimeFor('/x/take.oga'), 'audio/ogg');
    expect(audioMimeFor('/x/take.opus'), 'audio/ogg');
    expect(audioMimeFor('/x/take.mp3'), 'audio/mpeg');
    expect(audioMimeFor('/x/take.M4A'), 'audio/mp4');
    expect(audioMimeFor('/x/take.wav'), 'audio/wav');
    expect(audioMimeFor('/x/take.unknown'), 'audio/*');
  });
}
