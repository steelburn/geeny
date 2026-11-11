import 'dart:async';
import 'dart:collection';

import '../protocol/assembler.dart';
import '../protocol/crc.dart' show crc16, crc16Bytes, crc32;
import '../protocol/frame.dart';
import 'link.dart';

/// Heartbeat: msg_id and the in-payload counter are two separate sequences.
/// First frame observed from the app was msg_id=0x0015 with counter=0xfc15, then
/// msg_id=0x0016 with 0xfc2d, i.e. the counter advances by 0x18 per beat.
/// Sending anything else silently freezes the command channel.
const List<int> hbPrefix = [0x00, 0x60, 0x09, 0x00, 0x02, 0x0a];
const int hbIdStart = 0x0015;
const int hbCtrStart = 0xfc15;
const int hbCtrStep = 0x18;

const int chunkSize = 2090;

class DeviceInfo {
  DeviceInfo({required this.raw, required this.name, required this.serial});

  final Map<int, List<int>> raw;
  final String name;
  final String serial;

  /// Firmware is not exposed as a plain attribute; report the raw rows instead.
  Map<int, String> get attrs =>
      {for (final e in raw.entries) e.key: e.value.isEmpty ? '(empty)' : hex(e.value)};
}

class TransferProgress {
  const TransferProgress(this.offset, this.total);
  final int offset;
  final int total;
  double get fraction => total <= 0 ? 0 : (offset / total).clamp(0, 1).toDouble();
}

class NotraClient {
  NotraClient(this.transport, {this.debug = false});

  final Link transport;
  final bool debug;

  final Map<int, int> _chanSeq = {};
  int _hbId = hbIdStart;
  int _hbCtr = hbCtrStart;
  final FrameAssembler _asm = FrameAssembler();
  final Queue<Frame> _frames = Queue<Frame>();

  /// Called for every frame the device sends, before the session layer consumes
  /// it — this is what feeds the frame ledger in the UI.
  void Function(Frame frame)? onFrame;

  /// Real traffic counters, independent of how much of it the UI chooses to show.
  int sentCount = 0;
  int receivedCount = 0;

  bool get isConnected => transport.isConnected;

  int _nextId(int channel) {
    // msg ids are per-channel sequence numbers (1, 2, 3 … on each channel).
    final next = ((_chanSeq[channel] ?? 0) + 1) & 0xffff;
    _chanSeq[channel] = next;
    return next;
  }

  Future<void> _write(List<int> data) async {
    sentCount++;
    await transport.send(data);
  }

  Future<int> _send(int flags, int channel, List<int> payload,
      {List<int> dst = devNode}) async {
    final msgId = _nextId(channel);
    await _write(Frame(
        flags: flags, msgId: msgId, src: appNode, dst: dst, channel: channel, payload: payload)
        .encode());
    return msgId;
  }

  Future<Frame> _recvFrame(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('no frame within ${timeout.inMilliseconds} ms');
      _frames.addAll(_asm.feed(await transport.recv(left)));
      if (_frames.isNotEmpty) {
        final frame = _frames.removeFirst();
        receivedCount++;
        onFrame?.call(frame);
        return frame;
      }
    }
  }

  Future<void> connect() => transport.connect();
  Future<void> close() => transport.close();

  // --- operations -----------------------------------------------------------

  /// Keep-alive; the device stops serving commands if this is malformed.
  Future<void> heartbeat() async {
    final payload = <int>[
      ...hbPrefix,
      _hbCtr & 0xff,
      (_hbCtr >> 8) & 0xff,
      0, 0, 0, 0,
      0x2C,
    ];
    await _write(
      Frame(
        flags: flagRequest,
        msgId: _hbId,
        src: appNode,
        dst: const [0, 0, 0, 0],
        channel: 0x0000,
        payload: payload,
      ).encode(),
    );
    _hbId = (_hbId + 1) & 0xffff;
    _hbCtr = (_hbCtr + hbCtrStep) & 0xffff;
  }

  /// No-op placeholder for parity with the Python client's explicit call sites.
  Future<void> sleep(Duration d) => Future<void>.delayed(d);

  /// CMD_GET_INFO: empty payload on channel 0x15; device answers with a TLV blob.
  Future<DeviceInfo> getInfo({Duration timeout = const Duration(seconds: 6)}) async {
    await _send(flagStatus, chInfo, const []);
    final raw = <int, List<int>>{};
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      final Frame fr;
      try {
        fr = await _recvFrame(left);
      } on TimeoutException {
        break;
      }
      if (fr.channel != chInfo || fr.payload.isEmpty) continue;
      final body = fr.payload.sublist(0, fr.payload.length >= 2 ? fr.payload.length - 2 : 0);
      raw.addAll(tlvToDict(body));
      break;
    }
    final name = await getAttr(chName);
    final serial = await getAttr(chSn);
    return DeviceInfo(
      raw: raw,
      name: name == null ? '' : String.fromCharCodes(name).replaceAll('\u0000', '').trim(),
      serial: serial == null ? '' : String.fromCharCodes(serial).replaceAll('\u0000', '').trim(),
    );
  }

  Future<void> setMicGain(int db) async {
    if (db < 0 || db > 0xff) throw ArgumentError('gain must be 0..255');
    await setAttr(attrMicGain, [db]);
  }

  // --- record control -------------------------------------------------------
  //
  // Evidence (capture extrec2, vendor app 18:40-18:43):
  //   0x12 = 1, 0x0b = 1                  arm — device records from its own button
  //   0x13 = 1a 0b 0b 02 <tick u16le>     record context; tick advances ~4 per second
  //   0x0b = 0                            release, hands the device back
  //
  // Writing the context does not start a take on firmware v1.14 (three variants
  // The device acks the start command but does not allocate a file for a
  // third-party client, so a failed start is reported rather than hidden.

  static const int attrRelease = 0x0B;
  static const int attrFileId = 0x11;
  static const int attrArm = 0x12;
  static const int attrRecCtx = 0x13;
  static const int attrTransferMode = 0x16;

  // Verified against the vendor app under HCI snoop (2026-11-11, device clock 22:05):
  //   attr 0x01  battery percent   (0x47 = 71 %, matches the app's own display)
  //   attr 0x04  mic gain, dB      (0x18 = 24)
  //   attr 0x05  noise reduction   (01 on / 00 off, observed when the app toggled it)
  // VCS gain is NOT identified: the vendor slider could not be driven from adb and its
  // page writes nothing on open. Candidates 0x06..0x09 / 0x1e..0x20 are tried and
  // confirmed at runtime instead of being assumed here.
  static const int attrBattery = 0x01;
  static const int attrNoiseReduction = 0x05;

  /// Storage counters: total then free, both u32 little-endian **kilobytes**,
  /// followed by two reserved bytes. Decoded from the app's own status frame:
  /// total stayed at 7,675,904 KB while free fell from 7,673,856 to 7,673,792 KB
  /// as takes were recorded.
  static const int attrStorage = 0x15;

  /// Let the device record without the vendor app.
  Future<void> arm() async {
    await setAttr(attrArm, const [1]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await setAttr(attrRelease, const [1]);
  }

  /// Release the device so the vendor app can bind to it again.
  Future<void> deactivate() async {
    await setAttr(attrRelease, const [0]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await setAttr(attrArm, const [0]);
  }

  // --- record control -------------------------------------------------------
  //
  // Capture 2026-11-11 (vendor app, snoop on):
  //   0x16 = 2                          enter transfer/record mode
  //   ch 8008  81 01 00 01 + crc16      start the take
  //   ch 8008  80 01 00 01 + crc16      key of the allocated file (80 04 00 <key>)
  //   0x16 = 0                          stop
  // Channel-0x8008 payloads MUST carry the crc16; without it the device is silent.

  // Record control is just transfer mode. Verified on hardware 2026-11-11: with the
  // LED observed, `0x16 = 2` starts a take and holds the red light; `0x16 = 0` ends it.
  // Sending the vendor's extra registration writes (ctx 0x13, file id 0x11, 0x17) or the
  // channel-0x8008 start/key pair immediately after the start cancels the take — the
  // light blinks once and nothing is recorded.

  /// Start a take: transfer mode on. Nothing else may follow immediately.
  Future<void> recordStart() async {
    await setAttr(attrTransferMode, const [2]);
  }

  /// Stop the take: transfer mode off.
  Future<void> recordStop() async {
    await setAttr(attrTransferMode, const [0]);
  }

  // --- attribute layer ------------------------------------------------------

  /// Generic getter: `00 00 00` on a channel, reply `00 <value> <crc16>`.
  Future<List<int>?> getAttr(int channel,
      {Duration timeout = const Duration(seconds: 3)}) async {
    await _send(flagStatus, channel, const [0, 0, 0]);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      final Frame fr;
      try {
        fr = await _recvFrame(left);
      } on TimeoutException {
        break;
      }
      if (fr.channel == channel && fr.flags == flagData) {
        final body = fr.payload.length >= 2
            ? fr.payload.sublist(0, fr.payload.length - 2)
            : <int>[];
        return (body.isNotEmpty && body[0] == 0x00) ? body.sublist(1) : body;
      }
    }
    return null;
  }

  Future<List<int>?> readAttr(int channel) => getAttr(channel);

  Future<void> setAttr(int attr, List<int> value) async {
    final tlv = tlvPack(attr, value);
    await _send(flagStatus, chSettings, [...tlv, ...crc16Bytes(tlv)]);
  }

  // --- settings -------------------------------------------------------------

  /// The device's own settings/status table (channel 0x0021, TLV).
  Future<Map<int, List<int>>> readCaps({Duration timeout = const Duration(seconds: 3)}) async {
    final blob = await getAttr(chCaps, timeout: timeout);
    return blob == null ? {} : tlvToDict(blob);
  }

  /// Battery percentage as the device reports it (attr 0x01 of the status blob).
  static int? batteryPercent(Map<int, List<int>> caps) {
    final v = caps[attrBattery];
    if (v == null || v.isEmpty) return null;
    final pct = v.first;
    return pct <= 100 ? pct : null;
  }

  /// Total and free capacity of the recorder (attr 0x15), in kilobytes.
  static ({int totalKb, int freeKb})? storage(Map<int, List<int>> caps) {
    final v = caps[attrStorage];
    if (v == null || v.length < 10) return null;
    int u32(int at) =>
        v[at] | (v[at + 1] << 8) | (v[at + 2] << 16) | (v[at + 3] << 24);
    final total = u32(0);
    final free = u32(4);
    if (total <= 0 || free < 0 || free > total) return null;
    return (totalKb: total, freeKb: free);
  }

  /// Write a setting and confirm it by re-reading the device's table.
  ///
  /// Nothing here relies on a documented attribute map: if the device does not
  /// reflect the new value it is restored and false is returned, so the UI can
  /// say "not supported" instead of pretending.
  Future<bool> writeSetting(int attr, List<int> value,
      {Duration settle = const Duration(milliseconds: 450)}) async {
    final before = await readCaps();
    final original = before[attr];
    if (original == null) return false; // attribute not in the table
    await setAttr(attr, value);
    await Future<void>.delayed(settle);
    final after = await readCaps();
    final now = after[attr];
    if (now != null && hex(now) == hex(value)) return true;
    if (original.isNotEmpty) await setAttr(attr, original); // put it back
    return false;
  }

  // --- file transfer --------------------------------------------------------
  //
  // File traffic is a normal 0x55 frame (flags 0x10 request / 0x11 response) on
  // channel 0x8007 whose payload is:
  //
  //     aa | crc32(body) u32le | type | len u16le | body | crc16
  //
  // Verified from capture extrec2 msg 0014-0017:
  //
  //   host  86 02 00 e7 03                 poll for the pending take
  //   dev   86 0c 00 <key u32> <u32> <u32>  (or 90 01 00 01 = nothing pending)
  //   host  81 04 00 <key>                 -> 81 18 00 <hash16> <size u32> <chunks u32>
  //   host  82 08 00 <key> <offset u32>    -> the device streams every chunk, then
  //                                           sends 84 04 00 <key> = transfer complete
  //   host  85 04 00 <key>                 ack; the device echoes it

  static const List<int> _pollBody = [0x86, 0x02, 0x00, 0xE7, 0x03];

  static List<int> filePayload(List<int> body) {
    final c = crc32(body);
    final framed = <int>[
      0xAA,
      c & 0xff,
      (c >> 8) & 0xff,
      (c >> 16) & 0xff,
      (c >> 24) & 0xff,
      ...body,
    ];
    return [...framed, ...crc16Bytes(framed)];
  }

  /// Frames dropped because their checksums did not match. Silent by design: the
  /// user only sees that the transfer succeeded, the count lives in diagnostics.
  static int corruptFrames = 0;

  /// type + body of a file payload, or null when the frame is something else.
  ///
  /// Every file payload is `aa | crc32(body) | type | len u16 | body | crc16`;
  /// both checksums are verified here, so a chunk damaged on the air is dropped
  /// rather than written into the audio file.
  static (int, List<int>)? parseFilePayload(List<int> payload) {
    if (payload.length < 10 || payload[0] != 0xAA) return null;
    final body = payload.sublist(5, payload.length - 2);
    final want16 = payload[payload.length - 2] | (payload[payload.length - 1] << 8);
    if (crc16(payload.sublist(0, payload.length - 2)) != want16) {
      corruptFrames++;
      return null;
    }
    final want32 = payload[1] | (payload[2] << 8) | (payload[3] << 16) | (payload[4] << 24);
    if (crc32(body) != want32) {
      corruptFrames++;
      return null;
    }
    final kind = payload[5];
    final length = payload[6] | (payload[7] << 8);
    if (length == 0 || payload.length < 8 + length) {
      corruptFrames++;
      return null;
    }
    return (kind, payload.sublist(8, 8 + length));
  }

  Future<void> _fileSend(List<int> body) =>
      _send(flagStatus, chFile, filePayload(body));

  /// Ask for the pending take's key.
  ///
  /// A finished take is not published until transfer mode is cycled (capture
  /// 2026-11-11: 0x16=2 … 0x16=0 immediately before the key appears), so a miss
  /// is retried once after cycling.
  Future<int?> fileKey({
    Duration timeout = const Duration(seconds: 4),
    bool allowTransferCycle = true,
  }) async {
    final first = await _pollKey(timeout);
    if (first != null || !allowTransferCycle) return first;
    await setAttr(attrTransferMode, const [2]);
    await Future<void>.delayed(const Duration(seconds: 4));
    await setAttr(attrTransferMode, const [0]);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return _pollKey(timeout);
  }

  Future<int?> _pollKey(Duration timeout) async {
    await _fileSend(_pollBody);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      final Frame fr;
      try {
        fr = await _recvFrame(left);
      } on TimeoutException {
        break;
      }
      if (fr.channel != chFile || fr.flags != flagData) continue;
      final parsed = parseFilePayload(fr.payload);
      if (parsed == null) continue;
      final (kind, body) = parsed;
      if (kind == 0x86 && body.length >= 4) return readU32le(body, 0);
      // 0x90 = nothing pending; keep waiting until the deadline.
    }
    return null;
  }

  Future<Map<String, Object>> openLatest({bool allowTransferCycle = true}) async {
    final key = await fileKey(allowTransferCycle: allowTransferCycle);
    if (key == null) {
      throw StateError('device reported no current file key (no new recording?)');
    }
    await _fileSend([0x81, 0x04, 0x00, ...u32leBytes(key)]);
    final meta = await _recvKind(0x81, const Duration(seconds: 5));
    final info = <String, Object>{'key': key};
    if (meta != null && meta.length >= 24) {
      info['hash'] = hex(meta.sublist(0, 16));
      info['size'] = readU32le(meta, 16);
      info['chunks'] = readU32le(meta, 20);
    }
    return info;
  }

  /// One request, then read the stream to completion.
  Future<Uint8ListLike> pullLatest({
    void Function(TransferProgress)? progress,
    bool allowTransferCycle = true,
  }) async {
    final info = await openLatest(allowTransferCycle: allowTransferCycle);
    final key = info['key'] as int;
    final size = (info['size'] as int?) ?? 0;
    final data = <int>[];
    final pending = <int, List<int>>{};
    await _fileSend([0x82, 0x08, 0x00, ...u32leBytes(key), 0, 0, 0, 0]);

    var complete = false;
    var idle = 0;
    while (!complete) {
      final Frame fr;
      try {
        fr = await _recvFrame(const Duration(seconds: 6));
      } on TimeoutException {
        if (size > 0 && data.length >= size) break;
        if (++idle >= 3) break;
        continue;
      }
      if (fr.channel != chFile || fr.flags != flagData) continue;
      final parsed = parseFilePayload(fr.payload);
      if (parsed == null) continue;
      final (kind, body) = parsed;
      if (kind == 0x82 && body.length >= 10) {
        final off = readU32le(body, 4);
        final len = body[8] | (body[9] << 8);
        final chunk = body.sublist(10, 10 + len);
        if (off == data.length) {
          data.addAll(chunk);
          while (pending.containsKey(data.length)) {
            data.addAll(pending.remove(data.length)!);
          }
        } else if (off > data.length) {
          pending[off] = chunk;
        }
        progress?.call(TransferProgress(data.length, size));
      } else if (kind == 0x84) {
        complete = true;
      }
    }
    await _fileSend([0x85, 0x04, 0x00, ...u32leBytes(key)]);
    if (size > 0 && data.length < size) {
      throw StateError('incomplete pull: ${data.length} of $size bytes');
    }
    return size > 0 ? data.sublist(0, size) : data;
  }

  Future<List<int>?> _recvKind(int kind, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      final Frame fr;
      try {
        fr = await _recvFrame(left);
      } on TimeoutException {
        break;
      }
      if (fr.channel != chFile || fr.flags != flagData) continue;
      final parsed = parseFilePayload(fr.payload);
      if (parsed != null && parsed.$1 == kind) return parsed.$2;
    }
    return null;
  }
}

typedef Uint8ListLike = List<int>;
