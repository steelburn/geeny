/// CFDLink frame layer for the Boya Notra Neo.
///
/// Layout (verified on 952 live frames, see `research/PROTOCOL.md`):
///
///     0        0x55
///     1        flags         0x10 status/ack | 0x11 data response | 0x12 request
///     2..3     payload length, u16 LE
///     4..15    routing key: [msgId u16][src 4][dst 4][channel u16]
///     16..     payload
///     16+len   8-bit sum of all preceding bytes   (total = len + 17)
library;

import 'crc.dart';

const int start = 0x55;

const int flagStatus = 0x10;
const int flagData = 0x11;
const int flagRequest = 0x12;

/// Routing nodes (from the capture).
const List<int> appNode = [0x01, 0x01, 0x1d, 0x00];
const List<int> devNode = [0x01, 0x02, 0x25, 0x00];

/// Channels.
const int chInfo = 0x0015;
const int chSn = 0x0017;
const int chName = 0x0018;
const int chCaps = 0x0021;
const int chStatus = 0x0022;
const int chSettings = 0x001E;
const int chFile = 0x8007;
const int chFileCtl = 0x8008;

class Frame {
  const Frame({
    required this.flags,
    required this.msgId,
    required this.src,
    required this.dst,
    required this.channel,
    this.payload = const [],
  });

  final int flags;
  final int msgId;
  final List<int> src;
  final List<int> dst;
  final int channel;
  final List<int> payload;

  List<int> encode() {
    final key = <int>[
      msgId & 0xff,
      (msgId >> 8) & 0xff,
      ...src,
      ...dst,
      channel & 0xff,
      (channel >> 8) & 0xff,
    ];
    if (key.length != 12) {
      throw ArgumentError('routing key must be 12 bytes, got ${key.length}');
    }
    final body = <int>[
      start,
      flags,
      payload.length & 0xff,
      (payload.length >> 8) & 0xff,
      ...key,
      ...payload,
    ];
    return [...body, checksum(body)];
  }

  @override
  String toString() {
    final hex = payload.isEmpty
        ? '-'
        : payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'flags=${flags.toRadixString(16).padLeft(2, '0')} '
        'id=${msgId.toRadixString(16).padLeft(4, '0')} '
        'chan=${channel.toRadixString(16).padLeft(4, '0')} '
        'len=${payload.length} payload=$hex';
  }
}

int checksum(List<int> data) => data.fold(0, (a, b) => (a + b) & 0xff);

/// Decode one frame; throws [FormatException] on anything malformed.
Frame decode(List<int> data) {
  if (data.length < 17) {
    throw FormatException('frame too short (${data.length} bytes)');
  }
  if (data[0] != start) {
    throw FormatException('bad start byte 0x${data[0].toRadixString(16)}');
  }
  final flags = data[1];
  final length = data[2] | (data[3] << 8);
  final total = 16 + length;
  if (data.length < total + 1) {
    throw FormatException('truncated frame: need ${total + 1}, have ${data.length}');
  }
  if (checksum(data.sublist(0, total)) != data[total]) {
    throw const FormatException('checksum mismatch');
  }
  final key = data.sublist(4, 16);
  return Frame(
    flags: flags,
    msgId: key[0] | (key[1] << 8),
    src: key.sublist(2, 6),
    dst: key.sublist(6, 10),
    channel: key[10] | (key[11] << 8),
    payload: data.sublist(16, total),
  );
}

// --- TLV helpers -------------------------------------------------------------

/// Parse `[attr_id u8][len u8][value...]` records.
List<MapEntry<int, List<int>>> tlvParse(List<int> payload) {
  final out = <MapEntry<int, List<int>>>[];
  var i = 0;
  while (i + 2 <= payload.length) {
    final attr = payload[i];
    final len = payload[i + 1];
    if (i + 2 + len > payload.length) break;
    out.add(MapEntry(attr, payload.sublist(i + 2, i + 2 + len)));
    i += 2 + len;
  }
  return out;
}

List<int> tlvPack(int attr, List<int> value) {
  if (attr < 0 || attr > 0xff || value.length > 0xff) {
    throw ArgumentError('attr or value too large');
  }
  return [attr, value.length, ...value];
}

Map<int, List<int>> tlvToDict(List<int> payload) =>
    {for (final e in tlvParse(payload)) e.key: e.value};

const int attrMicGain = 0x04; // 1 byte, dB (verified: 0x12 = 18 dB, 0x18 = 24 dB)
const int attrFileId = 0x11;

// --- file channel framing ----------------------------------------------------

/// File-channel frame: `aa | crc32(body) LE | body | crc16`.
List<int> fileFrame(List<int> body) {
  final c = crc32(body);
  final framed = <int>[0xAA, c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, (c >> 24) & 0xff, ...body];
  return [...framed, ...crc16Bytes(framed)];
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String ascii(List<int> bytes) => bytes
    .map((b) => (b >= 32 && b < 127) ? String.fromCharCode(b) : '.')
    .join();

String u32le(int v) => hex(u32leBytes(v));

List<int> u32leBytes(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

int readU32le(List<int> b, int at) =>
    b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);
