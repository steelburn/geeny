import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ble/link.dart';
import '../ble/notra_client.dart';
import 'takes.dart';
import '../protocol/frame.dart';

enum LinkState { offline, scanning, connected }

enum LogKind { tx, rx, note, error }

class LogLine {
  LogLine(this.kind, this.text) : at = DateTime.now();
  final LogKind kind;
  final String text;
  final DateTime at;

  String get stamp =>
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
}

/// One session with one recorder: link, keep-alive, and the operations the UI
/// exposes. Everything the device says lands in [log], truncated to a sane window.
class Session extends ChangeNotifier {
  Session({NotraClient Function()? clientFactory})
      : _clientFactory = clientFactory ?? (() => NotraClient(BleLink(debug: true), debug: true));

  final NotraClient Function() _clientFactory;
  NotraClient? _client;
  Timer? _keepAlive;

  LinkState linkState = LinkState.offline;
  String? busy; // action key while a command is in flight
  String? error;
  DeviceInfo? info;
  int gain = 24;
  String address = '—';
  int mtu = 0;
  TransferProgress? transfer;
  bool recording = false;
  DateTime? _recordStartedAt;
  Timer? _recordTicker;

  /// How long the current take has been running.
  Duration get elapsed {
    final started = _recordStartedAt;
    if (!recording || started == null) return Duration.zero;
    return DateTime.now().difference(started);
  }

  static String clock(Duration d) =>
      '${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// Free space on the recorder, in the decimal GB the device is sold as.
  String? get storageLabel =>
      storageFreeKb == null ? null : _capacity(storageFreeKb!);
  String? get storageTotalLabel =>
      storageTotalKb == null ? null : _capacity(storageTotalKb!);

  static String _capacity(int kb) {
    final gb = kb / 1000000; // counters are kilobytes
    return gb >= 1 ? '${gb.toStringAsFixed(1)} GB' : '${(kb / 1000).round()} MB';
  }

  void _startTicker() {
    _recordTicker?.cancel();
    _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (recording) notifyListeners();
    });
  }

  void _stopTicker() {
    _recordTicker?.cancel();
    _recordTicker = null;
  }
  Map<int, List<int>> caps = {};          // the device's own settings table
  int get corruptFrames => NotraClient.corruptFrames;
  int? battery;                            // percent, from caps attr 0x01
  int? storageFreeKb;                      // recorder capacity, caps attr 0x15
  int? storageTotalKb;
  bool noiseReduction = false;
  int vcsLevel = 0;
  int? _vcsAttr;                           // discovered on first use
  String? settingsNote;
  final Takes takes = Takes();
  String? savedFile;
  String? notice;
  final List<LogLine> log = [];

  bool get connected => linkState == LinkState.connected;
  int get sentCount => _client?.sentCount ?? 0;
  int get receivedCount => _client?.receivedCount ?? 0;
  bool get isBusy => busy != null;

  void _emit(LogKind kind, String text) {
    log.add(LogLine(kind, text));
    if (log.length > 240) log.removeRange(0, log.length - 240);
    notifyListeners();
  }

  void clearLog() {
    log.clear();
    notifyListeners();
  }

  void dismissError() {
    error = null;
    notifyListeners();
  }

  Future<void> _run(String key, Future<void> Function(NotraClient client) body) async {
    final client = _client;
    if (client == null || !connected) {
      error = 'Not connected. Press Connect first.';
      notifyListeners();
      return;
    }
    if (busy != null) return;
    busy = key;
    error = null;
    notifyListeners();
    try {
      await body(client);
    } on TimeoutException catch (e) {
      error = 'The device did not answer in time (${e.message ?? 'no reply'}).';
      _emit(LogKind.error, e.toString());
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
      _emit(LogKind.error, e.toString());
    } finally {
      busy = null;
      notifyListeners();
    }
  }

  Future<void> connect() async {
    if (linkState != LinkState.offline || busy != null) return;
    error = null;
    linkState = LinkState.scanning;
    busy = 'connect';
    notifyListeners();
    final client = _clientFactory();
    _client = client;
    try {
      client.onFrame = _logRx;
      await client.connect();
      final link = client.transport;
      address = link is BleLink ? (link.device?.remoteId.str ?? '—') : '—';
      mtu = link is BleLink ? link.mtu : 0;
      linkState = LinkState.connected;
      busy = null;
      _emit(LogKind.note, 'link up · mtu $mtu · $address');
      notifyListeners();

      await client.heartbeat();
      _emit(LogKind.tx, 'heartbeat');
      _startKeepAlive();

      await _run('info', (c) async {
        info = await c.getInfo();
        await _refreshCaps(c);
        _emit(LogKind.note, _describe(info!));
      });
    } catch (e) {
      await client.close().catchError((_) {});
      _client = null;
      linkState = LinkState.offline;
      busy = null;
      error = e is NotraNotFoundException
          ? e.message
          : 'Could not connect: ${e.toString().replaceFirst('Exception: ', '')}';
      _emit(LogKind.error, error!);
    }
    notifyListeners();
  }

  void _logRx(Frame frame) {
    // The keep-alive telemetry channel repeats forever; the ledger is for traffic
    // that answers something.
    if (frame.channel == 0x0000) return;
    _emit(LogKind.rx, _shortFrame(frame));
  }

  static String _shortFrame(Frame f) {
    final hexed = hex(f.payload);
    final body = hexed.length <= 64 ? hexed : '${hexed.substring(0, 64)}…';
    return 'ch ${f.channel.toRadixString(16).padLeft(4, '0')} · '
        '${f.payload.length} B · ${body.isEmpty ? 'no payload' : body}';
  }

  String _describe(DeviceInfo i) {
    final parts = <String>[
      if (i.name.isNotEmpty) 'name “${i.name}”',
      if (i.serial.isNotEmpty) 'serial ${i.serial}',
      '${i.raw.length} attributes',
    ];
    return parts.join(' · ');
  }

  void _startKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(const Duration(seconds: 4), (_) async {
      final c = _client;
      if (c == null || !connected || busy != null) return;
      try {
        await c.heartbeat();
      } catch (_) {
        // A dropped beat is not fatal.
      }
    });
  }

  Future<void> disconnect() async {
    _keepAlive?.cancel();
    _keepAlive = null;
    final c = _client;
    _client = null;
    await c?.close().catchError((_) {});
    linkState = LinkState.offline;
    busy = null;
    info = null;
    transfer = null;
    _emit(LogKind.note, 'link down');
    notifyListeners();
  }

  Future<void> heartbeat() => _run('heartbeat', (c) async {
        await c.heartbeat();
        _emit(LogKind.tx, 'heartbeat');
      });

  Future<void> readDevice() => _run('info', (c) async {
        info = await c.getInfo();
        await _refreshCaps(c);
        _emit(LogKind.note, _describe(info!));
      });

  Future<void> applyGain(int db) => _run('gain', (c) async {
        gain = db.clamp(0, 30);
        await c.setMicGain(gain);
        _emit(LogKind.note, 'mic gain → $gain dB (attr 0x04)');
        notice = 'Mic gain set to $gain dB.';
      });

  /// Arm the device so it records without the vendor app.
  Future<void> arm() => _run('arm', (c) async {
        await c.arm();
        _emit(LogKind.note, 'armed (attr 0x12 = 1, attr 0x0b = 1)');
        notice = 'Recorder armed. Press the button on the device, then Fetch latest.';
      });

  Future<void> _refreshCaps(NotraClient c) async {
    caps = await c.readCaps();
    battery = NotraClient.batteryPercent(caps);
    final storage = NotraClient.storage(caps);
    storageFreeKb = storage?.freeKb;
    storageTotalKb = storage?.totalKb;
    final nr = caps[NotraClient.attrNoiseReduction];
    if (nr != null && nr.isNotEmpty) noiseReduction = nr.first != 0;
    final vcs = _vcsAttr == null ? null : caps[_vcsAttr!];
    if (vcs != null && vcs.isNotEmpty) vcsLevel = vcs.first;
    notifyListeners();
  }

  Future<void> refreshSettings() => _run('settings', (c) async {
        await _refreshCaps(c);
      });

  /// Noise reduction: attr 0x05, confirmed against the device's own table.
  Future<void> toggleNoiseReduction(bool on) => _run('settings', (c) async {
        final ok = await c.writeSetting(NotraClient.attrNoiseReduction, [on ? 1 : 0]);
        await _refreshCaps(c);
        settingsNote = ok
            ? null
            : 'Noise reduction did not stick — this firmware reports no change.';
        _emit(LogKind.note, 'noise reduction -> ${on ? 'on' : 'off'} (${ok ? 'confirmed' : 'refused'})');
      });

  /// VCS gain: the attribute is not documented, so the first candidate that the
  /// device actually reflects is adopted and remembered.
  Future<void> setVcsGain(int level) => _run('settings', (c) async {
        const candidates = [0x06, 0x07, 0x08, 0x09, 0x1e, 0x1f, 0x20];
        final ordered = [?_vcsAttr, ...candidates.where((a) => a != _vcsAttr)];
        var ok = false;
        for (final attr in ordered) {
          if (!caps.containsKey(attr)) continue;
          if (await c.writeSetting(attr, [level])) {
            _vcsAttr = attr;
            ok = true;
            break;
          }
        }
        await _refreshCaps(c);
        settingsNote = ok ? null : 'VCS gain was not accepted by this firmware.';
        _emit(LogKind.note, 'vcs gain -> $level (${ok ? 'attr 0x${_vcsAttr!.toRadixString(16)}' : 'refused'})');
      });

  /// Record/Stop toggle.
  ///
  /// Start writes the sequence captured from the vendor app; the device acks it but
  /// usually refuses to allocate a file for a third-party client, so the outcome is
  /// reported instead of assumed.
  Future<void> recordToggle() => _run('record', (c) async {
        if (!recording) {
          await c.recordStart();
          recording = true;
          _recordStartedAt = DateTime.now();
          _startTicker();
          _emit(LogKind.note, 'record start (0x16 = 2)');
          notice = 'Recording. Stop when you are done, then fetch the take.';
        } else {
          final started = _recordStartedAt;
          final elapsed = started == null ? Duration.zero : DateTime.now().difference(started);
          await c.recordStop();
          _stopTicker();
          recording = false;
          _recordStartedAt = null;
          _emit(LogKind.note, 'record stop sent after ${elapsed.inSeconds}s (0x16 = 0)');
          notice = 'Stopped. Pull latest to fetch the take.';
        }
      });

  /// Hand the device back so the vendor app can bind again.
  Future<void> deactivate() => _run('deactivate', (c) async {
        await c.deactivate();
        recording = false;
        _recordStartedAt = null;
        _emit(LogKind.note, 'released (attr 0x0b = 0, attr 0x12 = 0)');
        notice = 'Handed back — the official app can connect to it again.';
      });

  Future<void> pullLatest() => _run('pull', (c) async {
        notice = 'Opening the current recording…';
        transfer = const TransferProgress(0, 0);
        // Never cycle transfer mode while a take is running: that would end it.
        final bytes = await c.pullLatest(
          allowTransferCycle: !recording,
          progress: (p) {
            transfer = p;
            notifyListeners();
          },
        );
        final dir = await getApplicationDocumentsDirectory();
        final stamp = DateTime.now()
            .toIso8601String()
            .replaceAll(':', '')
            .replaceAll('.', '')
            .substring(0, 15);
        final file = File('${dir.path}/notra-$stamp.ogg');
        await file.writeAsBytes(bytes);
        _emit(LogKind.note, 'saved ${file.path} (${bytes.length} bytes)');
        await takes.refresh();
        savedFile = file.path;
        notice = 'Saved ${_mb(bytes.length)} → ${file.path}';
      });

  static String _mb(int bytes) =>
      bytes < 1024 ? '$bytes B' : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';

  @override
  void dispose() {
    _stopTicker();
    takes.dispose();
    _keepAlive?.cancel();
    _client?.close().catchError((_) {});
    super.dispose();
  }
}
