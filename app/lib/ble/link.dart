import 'dart:async';
import 'dart:collection';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Wire-level transport. The session layer only needs send/recv, so the BLE
/// details stay here and a replay transport can slot in for offline tests.
abstract class Link {
  Future<void> connect();
  Future<void> send(List<int> data);
  Future<List<int>> recv(Duration timeout);
  Future<void> close();
  bool get isConnected;
}

const String serviceUuid = 'd8528400-66f0-40ff-8f3d-bc7a9853e04a';
const String chrWriteUuid = 'd8528401-66f0-40ff-8f3d-bc7a9853e04a';
const String chrNotifyUuid = 'd8528402-66f0-40ff-8f3d-bc7a9853e04a';
const String chrReadUuid = 'd8528403-66f0-40ff-8f3d-bc7a9853e04a';

const String deviceName = 'Boya Notra Neo';

class NotraNotFoundException implements Exception {
  final String message;
  NotraNotFoundException(this.message);
  @override
  String toString() => message;
}

class BleLink implements Link {
  BleLink({this.debug = false});

  final bool debug;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _write;
  final Queue<List<int>> _inbox = Queue<List<int>>();
  final Queue<Completer<List<int>>> _waiters = Queue<Completer<List<int>>>();
  StreamSubscription<List<int>>? _notify;
  bool _connected = false;

  BluetoothDevice? get device => _device;
  int get mtu => _device?.mtuNow ?? 23;

  void _onData(List<int> value) {
    if (debug) {
      // ignore: avoid_print
      print('  <- ${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
    }
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(value);
    } else {
      _inbox.add(value);
    }
  }

  @override
  bool get isConnected => _connected;

  /// Scan by service/name; returns the first Notra the radio offers.
  static Future<ScanResult> find({Duration timeout = const Duration(seconds: 25)}) async {
    await FlutterBluePlus.stopScan();
    final found = Completer<ScanResult>();
    final seen = <String>{};
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final adv = r.advertisementData.advName;
        final platform = r.device.platformName;
        if (adv.isNotEmpty) seen.add(adv);
        if (platform.isNotEmpty) seen.add(platform);
        final name = (adv.isNotEmpty ? adv : platform).toLowerCase();
        if (!found.isCompleted &&
            (name.contains('boya') || name.contains('notra') || platform.toLowerCase().contains('notra'))) {
          found.complete(r);
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(
        timeout: timeout,
        androidUsesFineLocation: false,
      );
      return await found.future.timeout(timeout + const Duration(seconds: 3),
          onTimeout: () => throw NotraNotFoundException(seen.isEmpty
              ? 'No Bluetooth devices in range. Is Bluetooth on, and is the recorder awake (short press)?'
              : 'No Notra found among ${seen.length} devices in range (${seen.take(4).join(', ')}). '
                  'Wake the recorder with a short press and make sure the vendor app is not holding it.'));
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  @override
  Future<void> connect() async {
    final result = await find();
    _device = result.device;
    await _device!.connect(
      license: License.nonprofit, // personal use, see flutter_blue_plus LICENSE.md
      timeout: const Duration(seconds: 25),
    );
    try {
      await _device!.requestMtu(512);
    } catch (_) {
      // Android negotiates 512 by default; a refusal only costs throughput.
    }
    // Must rediscover after every (re)connection.
    final services = await _device!.discoverServices();
    BluetoothCharacteristic? write;
    BluetoothCharacteristic? notify;
    for (final s in services) {
      if (s.serviceUuid != Guid(serviceUuid)) continue;
      for (final c in s.characteristics) {
        final uuid = c.characteristicUuid.toString().toLowerCase();
        if (uuid == chrWriteUuid) write = c;
        if (uuid == chrNotifyUuid) notify = c;
      }
    }
    if (write == null || notify == null) {
      throw StateError('service $serviceUuid found but write/notify characteristics are missing');
    }
    _write = write;
    _notify = notify.onValueReceived.listen(_onData);
    await notify.setNotifyValue(true);
    _connected = true;
  }

  @override
  Future<void> send(List<int> data) async {
    final chr = _write;
    if (chr == null) throw StateError('not connected');
    if (debug) {
      // ignore: avoid_print
      print('  -> ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
    }
    await chr.write(data, withoutResponse: true);
  }

  @override
  Future<List<int>> recv(Duration timeout) {
    if (_inbox.isNotEmpty) return Future.value(_inbox.removeFirst());
    final c = Completer<List<int>>();
    _waiters.add(c);
    return c.future.timeout(timeout, onTimeout: () {
      _waiters.remove(c);
      throw TimeoutException('no notification within ${timeout.inMilliseconds} ms');
    });
  }

  @override
  Future<void> close() async {
    _connected = false;
    await _notify?.cancel();
    _notify = null;
    _write = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _inbox.clear();
  }
}
