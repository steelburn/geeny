import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:notra_app/ble/link.dart';
import 'package:notra_app/ble/notra_client.dart';
import 'package:notra_app/protocol/crc.dart';
import 'package:notra_app/protocol/frame.dart';

/// A stand-in for the recorder: answers the same frames the hardware answers,
/// with payloads copied from the live capture. Proves the Dart session layer
/// end-to-end without a radio.
class FakeNotraLink implements Link {
  FakeNotraLink();

  final Queue<List<int>> _in = Queue<List<int>>();
  final List<List<int>> sentFrames = [];
  int key = 0x6AF37A55;
  bool hasTake = true;
  /// The device's own settings/status table, served on channel 0x0021.
  final Map<int, List<int>> caps = {
    0x01: [0x53], // battery 83%
    0x04: [0x18], // mic gain 24 dB
    0x05: [0x01], // noise reduction on
    0x06: [0x00],
  };
  bool publishOnTransferCycle = false;
  bool _sawTransferOn = false;
  List<int>? lastGainWrite;
  bool connected = false;
  int size = 3000;

  static final nameBytes = 'Boya Notra Neo'.codeUnits;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<void> close() async => connected = false;

  void _reply(Frame request, List<int> payload, {int flags = flagData}) {
    _in.add(Frame(
      flags: flags,
      msgId: request.msgId,
      src: devNode,
      dst: appNode,
      channel: request.channel,
      payload: payload,
    ).encode());
  }

  void _replyFile(Frame request, List<int> body) =>
      _reply(request, NotraClient.filePayload(body));

  @override
  Future<void> send(List<int> data) async {
    sentFrames.add(data);
    final f = decode(data);
    if (f.channel == chCaps) {
      final blob = <int>[];
      for (final e in caps.entries) {
        blob.addAll(tlvPack(e.key, e.value));
      }
      _reply(f, [0x00, ...blob, ...crc16Bytes(blob)]);
      return;
    }
    if (f.channel == chSettings) {
      final body = f.payload.sublist(0, f.payload.length - 2);
      final crcOk = crc16(body) == (f.payload[f.payload.length - 2] | (f.payload.last << 8));
      expect(crcOk, isTrue, reason: 'settings write must carry a valid crc16');
      if (body.isNotEmpty && body[0] == attrMicGain) lastGainWrite = body;
      if (body.length >= 3 && body[1] >= 1) {
        caps[body[0]] = body.sublist(2, 2 + body[1]); // the device reflects writes
      }
      if (body.isNotEmpty && body[0] == NotraClient.attrTransferMode) {
        if (body.length > 2 && body[2] == 2) _sawTransferOn = true;
        if (publishOnTransferCycle && body.length > 2 && body[2] == 0 && _sawTransferOn) hasTake = true;
      }
      _reply(f, [0x00, ...tlvPack(body[0], body.sublist(2, 2 + body[1])), ...crc16Bytes(body)]);
      return;
    }
    switch (f.channel) {
      case chInfo:
        final tlv = tlvPack(0x01, [0x53]);
        _reply(f, [...tlv, ...crc16Bytes(tlv)]);
      case chName:
        final body = [0x00, ...nameBytes];
        _reply(f, [...body, ...crc16Bytes(body)]);
      case chSn:
        final body = [0x00, ...'GL3410314055W'.codeUnits];
        _reply(f, [...body, ...crc16Bytes(body)]);
      case chFileCtl:
        final body = f.payload.sublist(0, f.payload.length - 2);
        if (body.isNotEmpty && body[0] == 0x81) {
          // 81 08 00 … 2c — the device's acknowledgement of a start
          final ack = [0x81, 0x08, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x2c];
          _reply(f, [...ack, ...crc16Bytes(ack)]);
        } else if (body.isNotEmpty && body[0] == 0x80) {
          final alloc = [0x80, 0x04, 0x00, ...u32leBytes(key)];
          _reply(f, [...alloc, ...crc16Bytes(alloc)]);
        }
      case chFile:
        final parsed = NotraClient.parseFilePayload(f.payload);
        if (parsed == null) return;
        final (kind, body) = parsed;
        switch (kind) {
          case 0x86: // poll
            if (!hasTake) {
              _replyFile(f, [0x90, 0x01, 0x00, 0x01]);
            } else {
              _replyFile(f, [0x86, 0x0C, 0x00, ...u32leBytes(key), 0, 0, 0, 0, 0, 0, 0, 0]);
            }
          case 0x81: // open -> hash, size, chunks
            _replyFile(f, [
              0x81, 0x18, 0x00,
              ...List<int>.filled(16, 0xAB),
              ...u32leBytes(size),
              ...u32leBytes((size / chunkSize).ceil()),
            ]);
          case 0x82: // stream every chunk, then completion
            for (var off = 0; off < size; off += chunkSize) {
              final len = (size - off).clamp(0, chunkSize);
              _replyFile(f, [
                0x82, (len + 10) & 0xff, ((len + 10) >> 8) & 0xff,
                ...u32leBytes(off ~/ chunkSize),
                ...u32leBytes(off),
                len & 0xff, (len >> 8) & 0xff,
                ...List<int>.generate(len, (i) => (off + i) & 0xff),
              ]);
            }
            _replyFile(f, [0x84, 0x04, 0x00, ...u32leBytes(key)]);
          case 0x85:
            _replyFile(f, [0x85, 0x04, 0x00, ...u32leBytes(key)]);
        }
    }
  }

  @override
  Future<List<int>> recv(Duration timeout) {
    if (_in.isEmpty) throw TimeoutException('no notification', timeout);
    return Future.value(_in.removeFirst());
  }
}

void main() {
  test('fileKey returns null when the device has nothing pending', () async {
    final link = FakeNotraLink()..hasTake = false;
    final client = NotraClient(link);
    await client.connect();
    expect(await client.fileKey(), isNull);
    await client.close();
  });

  test('session reads identity and writes mic gain over the fake link', () async {
    final link = FakeNotraLink();
    final client = NotraClient(link);
    await client.connect();
    await client.heartbeat();

    final info = await client.getInfo();
    expect(info.name, 'Boya Notra Neo');
    expect(info.serial, 'GL3410314055W');
    expect(info.raw[0x01], [0x53]);

    await client.setMicGain(18);
    expect(link.lastGainWrite, [0x04, 0x01, 0x12]);

    await client.setMicGain(24);
    expect(link.lastGainWrite, [0x04, 0x01, 0x18]);

    await client.close();
    expect(link.connected, isFalse);
  });

  test('heartbeat advances both sequences', () async {
    final link = FakeNotraLink();
    final client = NotraClient(link);
    await client.connect();
    await client.heartbeat();
    await client.heartbeat();
    final beats = link.sentFrames.map(decode).where((f) => f.channel == 0x0000).toList();
    expect(beats, hasLength(2));
    expect(beats[0].msgId, 0x0015);
    expect(beats[1].msgId, 0x0016);
    // payload counter: 0xfc15 then 0xfc2d
    expect(beats[0].payload.sublist(6, 8), [0x15, 0xfc]);
    expect(beats[1].payload.sublist(6, 8), [0x2d, 0xfc]);
  });

  test('arm writes 0x12=1 then 0x0b=1', () async {
    final link = FakeNotraLink();
    final client = NotraClient(link);
    await client.connect();
    await client.arm();
    final writes = link.sentFrames
        .map(decode)
        .where((f) => f.channel == chSettings)
        .map((f) => hex(f.payload.sublist(0, f.payload.length - 2)))
        .toList();
    expect(writes, ['120101', '0b0101']);
    await client.close();
  });

  test('deactivate releases with 0x0b=0 then 0x12=0', () async {
    final link = FakeNotraLink();
    final client = NotraClient(link);
    await client.connect();
    await client.deactivate();
    final writes = link.sentFrames
        .map(decode)
        .where((f) => f.channel == chSettings)
        .map((f) => hex(f.payload.sublist(0, f.payload.length - 2)))
        .toList();
    expect(writes, ['0b0100', '120100']);
    await client.close();
  });

  test('battery comes from the device table', () async {
    final link = FakeNotraLink();
    final client = NotraClient(link);
    await client.connect();
    final caps = await client.readCaps();
    expect(NotraClient.batteryPercent(caps), 0x53);
    await client.close();
  });

  test('a setting counts only when the device reflects it', () async {
    final link = FakeNotraLink();
    final client = NotraClient(link);
    await client.connect();

    expect(await client.writeSetting(0x05, [0]), isTrue,
        reason: 'the fake reflects writes, so this must confirm');
    expect((await client.readCaps())[0x05], [0]);

    expect(await client.writeSetting(0x99, [1]), isFalse,
        reason: 'an attribute the device does not expose must be refused');

    await client.close();
  });

  test('record start and stop are transfer mode on and off, nothing else', () async {
    final link = FakeNotraLink();
    final client = NotraClient(link);
    await client.connect();

    await client.recordStart();
    await client.recordStop();

    final writes = link.sentFrames
        .map(decode)
        .map((f) => hex(f.payload.sublist(0, f.payload.length - 2)))
        .toList();
    expect(writes, ['160102', '160100'],
        reason: 'extra writes after the start are what cancel a take on the device');

    await client.close();
  });

  test('a take appears only after transfer mode is cycled', () async {
    final link = FakeNotraLink()
      ..hasTake = false
      ..publishOnTransferCycle = true;
    final client = NotraClient(link);
    await client.connect();
    expect(await client.fileKey(), link.key,
        reason: 'fileKey must cycle 0x16 to publish a finished take');
    final cycles = link.sentFrames
        .map(decode)
        .where((f) => f.channel == chSettings)
        .where((f) => f.payload.isNotEmpty && f.payload[0] == NotraClient.attrTransferMode)
        .length;
    expect(cycles, 2, reason: 'on, then off');
    await client.close();
  });

  test('pullLatest reassembles the ogg stream and closes the transfer', () async {
    final link = FakeNotraLink();
    final client = NotraClient(link);
    await client.connect();
    final bytes = await client.pullLatest();
    expect(bytes, hasLength(3000));
    expect(bytes.first, 0);
    expect(bytes.last, 2999 & 0xff);
    // The host acknowledges completion with 85 04 00 <key>.
    final acks = link.sentFrames
        .map(decode)
        .where((f) => f.channel == chFile)
        .map((f) => NotraClient.parseFilePayload(f.payload))
        .whereType<(int, List<int>)>()
        .where((p) => p.$1 == 0x85)
        .toList();
    expect(acks, hasLength(1), reason: 'transfer must be acked');

    // Chunk requests happen once, not per chunk: the device streams the rest.
    final requests = link.sentFrames
        .map(decode)
        .where((f) => f.channel == chFile)
        .map((f) => NotraClient.parseFilePayload(f.payload))
        .whereType<(int, List<int>)>()
        .where((p) => p.$1 == 0x82)
        .toList();
    expect(requests, hasLength(1), reason: 'one request per stream');
  });

  test('storage counters decode total and free kilobytes', () {
    // Captured from the device: total 7,675,904 KB, free 7,673,856 KB.
    final caps = {
      NotraClient.attrStorage: [
        0x00, 0x20, 0x75, 0x00,
        0x00, 0x18, 0x75, 0x00,
        0x00, 0x00,
      ],
    };
    final storage = NotraClient.storage(caps);
    expect(storage, isNotNull);
    expect(storage!.totalKb, 7675904);
    expect(storage.freeKb, 7673856);
  });

  test('nonsense storage counters are ignored, not shown as capacity', () {
    expect(NotraClient.storage({NotraClient.attrStorage: [1, 2, 3]}), isNull);
    expect(
      NotraClient.storage({
        NotraClient.attrStorage: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      }),
      isNull,
    );
    // more free than total cannot be true
    expect(
      NotraClient.storage({
        NotraClient.attrStorage: [100, 0, 0, 0, 200, 0, 0, 0, 0, 0],
      }),
      isNull,
    );
  });
}
