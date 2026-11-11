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
        ...page(48000 * 3),
        ...page(48000 * 48), // 48 s, terminal page (granules are 48 kHz)
      ]);
    expect(Take.readDuration(file).inSeconds, 48);
  });

  test('a 16 kHz mono take is not three times its real length', () {
    // What the recorder actually writes: Ogg Opus at 16 kHz, granule at 48 kHz.
    final file = File('${dir.path}/recorder.ogg')
      ..writeAsBytesSync([
        ...page(0),
        ...page(48000 * 4671),
      ]);
    expect(Take.readDuration(file).inSeconds, 4671);
  });

  test('a corrupt middle page does not turn minutes into hours', () {
    final file = File('${dir.path}/damaged.ogg')
      ..writeAsBytesSync([
        ...page(0),
        ...page(0x0A0E0000), // garbage granule in one damaged page
        ...page(48000 * 48),
      ]);
    expect(Take.readDuration(file).inSeconds, 48);
  });

  test('a file with no Ogg pages has no duration', () {
    final file = File('${dir.path}/empty.ogg')..writeAsBytesSync(Uint8List(64));
    expect(Take.readDuration(file), Duration.zero);
  });

  // --- imported containers -------------------------------------------------

  /// MPEG 1 Layer III, 128 kbit/s, 44.1 kHz, mono: a 417-byte frame.
  List<int> mp3Frame({int mode = 3}) => [
        0xFF, 0xFB, 0x90, mode << 6, // header: bitrate index 9, rate index 0
        ...List<int>.filled(413, 0),
      ];

  test('an imported MP3 gets its length from its frames', () {
    // 100 frames = 100 * 1152 / 44100 s ~ 2.6 s
    final file = File('${dir.path}/boya-field-recording.mp3')
      ..writeAsBytesSync([for (var i = 0; i < 100; i++) ...mp3Frame()]);
    expect(Take.readDuration(file).inMilliseconds, 2612);
  });

  test('an MP3 with an ID3v2 tag in front is read past the tag', () {
    final tag = <int>[0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A];
    final file = File('${dir.path}/tagged.mp3')
      ..writeAsBytesSync([...tag, ...List<int>.filled(10, 0), for (var i = 0; i < 100; i++) ...mp3Frame()]);
    expect(Take.readDuration(file).inMilliseconds, 2612);
  });

  test('an imported WAV gets its length from the data chunk', () {
    ByteData header() {
      final b = ByteData(44);
      void ascii(int at, String s) {
        for (var i = 0; i < s.length; i++) {
          b.setUint8(at + i, s.codeUnitAt(i));
        }
      }

      ascii(0, 'RIFF');
      b.setUint32(4, 36 + 24000, Endian.little);
      ascii(8, 'WAVE');
      ascii(12, 'fmt ');
      b.setUint32(16, 16, Endian.little);
      b.setUint16(20, 1, Endian.little);
      b.setUint16(22, 1, Endian.little);
      b.setUint32(24, 8000, Endian.little);
      b.setUint32(28, 8000, Endian.little); // 8 kHz, mono, 8-bit
      b.setUint16(32, 1, Endian.little);
      b.setUint16(34, 8, Endian.little);
      ascii(36, 'data');
      b.setUint32(40, 24000, Endian.little);
      return b;
    }

    final file = File('${dir.path}/imported.wav')
      ..writeAsBytesSync([...header().buffer.asUint8List(), ...List<int>.filled(24000, 0)]);
    expect(Take.readDuration(file).inSeconds, 3);
  });

  test('an imported FLAC gets its length from STREAMINFO', () {
    final body = List<int>.filled(34, 0);
    const rate = 44100;
    const samples = 44100 * 3;
    final high = (rate << 12) | (samples >> 32);
    for (var i = 0; i < 4; i++) {
      body[10 + i] = (high >> (24 - 8 * i)) & 0xFF;
      body[14 + i] = (samples >> (24 - 8 * i)) & 0xFF;
    }
    final file = File('${dir.path}/imported.flac')
      ..writeAsBytesSync([
        0x66, 0x4C, 0x61, 0x43, // fLaC
        0x00, 0x00, 0x00, 34, // STREAMINFO, 34 bytes
        ...body,
      ]);
    expect(Take.readDuration(file).inSeconds, 3);
  });

  test('the library lists every format the import accepts', () {
    for (final ext in ['ogg', 'opus', 'oga', 'wav', 'mp3', 'm4a', 'aac', 'flac', 'amr']) {
      expect(Take.isAudioPath('/docs/boya-x-2026.$ext'), isTrue, reason: ext);
    }
    expect(Take.isAudioPath('/docs/imported-x.mp3.notes.json'), isFalse);
    expect(Take.isAudioPath('/docs/library.json'), isFalse);
    expect(Take.isAudioPath('/docs/no-extension'), isFalse);
  });

  test('a take without audio reads as notes only', () {
    final take = Take(
      file: File('${dir.path}/imported.ogg'),
      bytes: 0,
      modified: DateTime(2026, 11, 11),
      hasAudio: false,
    );
    expect(take.meta, 'notes only');
    expect(take.hasAudio, isFalse);
  });
}
