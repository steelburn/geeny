import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/protocol/assembler.dart';
import 'package:geeny_app/protocol/crc.dart';
import 'package:geeny_app/ble/notra_client.dart';
import 'package:geeny_app/protocol/frame.dart';

List<int> fromHex(String s) => [
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)
    ];

/// Known-good frames lifted from the live capture (mirrors tests/test_frame.py).
const cases = <(String, int, int, String)>[
  ('55100000010001011d00010225001500c2', 0x10, 0x0015, ''),
  ('55120d00150001011d0000000000000000600900020a15fc000000002c5a', 0x12, 0x0000, '006009'),
  ('55120d00d30c0102250001011d00000000980800020ae4923300bc0224d1', 0x12, 0x0000, '009808'),
  (
    '5511180004000102250001011d000100000f426f7961204e6f747261204e656f0040c001a0f14a25cb',
    0x11,
    0x0001,
    '000f426f7961204e6f747261204e656f'
  ),
  ('55100500020001011d00010225001e0012010160559a', 0x10, 0x001E, '120101'),
];

void main() {
  test('known-good frames decode, match fields and round-trip', () {
    for (final (hexStr, flags, chan, prefix) in cases) {
      final fr = decode(fromHex(hexStr));
      expect(fr.flags, flags, reason: hexStr);
      expect(fr.channel, chan, reason: hexStr);
      expect(hex(fr.payload), startsWith(prefix), reason: hexStr);
      expect(hex(decode(fr.encode()).payload), hex(fr.payload), reason: 'round-trip $hexStr');
    }
  });

  test('corrupted frame is rejected', () {
    final bad = fromHex(cases.first.$1)..[5] ^= 0xFF;
    expect(() => decode(bad), throwsFormatException);
  });

  test('TLV parse and pack', () {
    final blob = fromHex('010153040118050101060100150c00207500001875000000');
    final parsed = tlvParse(blob);
    expect(parsed.first.key, 0x01);
    expect(hex(parsed.first.value), '53');
    expect(parsed.map((e) => e.key), [0x01, 0x04, 0x05, 0x06]);
    expect(hex(tlvPack(0x04, [0x18])), '040118');
  });

  test('crc16 matches device-verified values', () {
    // TLV for mic gain 18 dB -> c0 5c ; activation attr 0x12 = 1 -> 60 55
    expect(hex(crc16Bytes(tlvPack(0x04, [0x12]))), 'c05c');
    expect(hex(crc16Bytes(tlvPack(0x12, [0x01]))), '6055');
  });

  test('crc32 matches zlib', () {
    expect(crc32([0x31, 0x32, 0x33]).toRadixString(16), '884863d2');
  });

  test('assembler stitches a frame split across notifications', () {
    final frame = fromHex(cases[1].$1);
    final asm = FrameAssembler();
    var frames = asm.feed(frame.sublist(0, 5));
    expect(frames, isEmpty);
    frames = asm.feed(frame.sublist(5));
    expect(frames, hasLength(1));
    expect(frames.single.channel, 0x0000);
  });

  test('assembler resyncs over garbage', () {
    final asm = FrameAssembler();
    final frames = asm.feed([0x00, 0x11, 0xff, ...fromHex(cases.first.$1)]);
    expect(frames, hasLength(1));
  });

  test('a file payload with a damaged body is rejected', () {
    final clean = NotraClient.filePayload([0x82, 0x0A, 0x00, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(NotraClient.parseFilePayload(clean), isNotNull);

    final dirty = List<int>.from(clean)..[10] ^= 0xFF; // inside the body
    final before = NotraClient.corruptFrames;
    expect(NotraClient.parseFilePayload(dirty), isNull);
    expect(NotraClient.corruptFrames, before + 1);
  });

  test('file frame carries crc32 and crc16', () {
    final body = [0x81, 0x04, 0x00, 0x2a, 0x00, 0x00, 0x00];
    final framed = fileFrame(body);
    expect(framed[0], 0xAA);
    expect(framed.length, 1 + 4 + body.length + 2);
    expect(readU32le(framed, 1), crc32(body));
  });
}
