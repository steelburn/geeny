import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/state/takes.dart';

/// Build a minimal one-page Ogg stream with the given granule position.
List<int> page(int granule, {int bodyLength = 8}) {
  final header = <int>[
    0x4F, 0x67, 0x67, 0x53, // OggS
    0x00, // version
    0x00, // flags
    // granule, little endian
    granule & 0xFF,
    (granule >> 8) & 0xFF,
    (granule >> 16) & 0xFF,
    (granule >> 24) & 0xFF,
    0x00, 0x00, 0x00, 0x00, // serial
    0x00, 0x00, 0x00, 0x00, // sequence
    0x00, 0x00, 0x00, 0x00, // crc
    0x01, // segment count
    bodyLength, // segment table
  ];
  return [...header, ...List<int>.filled(bodyLength, 0)];
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('geeny_ogg_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('duration comes from the last page', () {
    final file = File('${dir.path}/take.ogg')
      ..writeAsBytesSync([
        ...page(0),
        ...page(16000 * 10),
        ...page(16000 * 48), // 48 s, terminal page
      ]);
    expect(Take.readDuration(file).inSeconds, 48);
  });

  test('a corrupt middle page does not turn minutes into hours', () {
    final file = File('${dir.path}/damaged.ogg')
      ..writeAsBytesSync([
        ...page(0),
        ...page(0x0A0E0000), // garbage granule in one damaged page
        ...page(16000 * 48),
      ]);
    expect(Take.readDuration(file).inSeconds, 48);
  });

  test('a file with no Ogg pages has no duration', () {
    final file = File('${dir.path}/empty.ogg')..writeAsBytesSync(Uint8List(64));
    expect(Take.readDuration(file), Duration.zero);
  });

  test('a notes-only take reads as transcript only', () {
    final take = Take(
      file: File('${dir.path}/imported.ogg'),
      bytes: 0,
      modified: DateTime(2026, 11, 11),
      hasAudio: false,
    );
    expect(take.meta, 'transcript only');
    expect(take.hasAudio, isFalse);
  });
}
