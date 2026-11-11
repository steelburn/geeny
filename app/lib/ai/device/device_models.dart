import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// What an on-device model is for.
enum ModelKind { speech, summary }

/// One downloadable model for the on-device pipeline.
///
/// Speech is a sherpa-onnx whisper bundle (three files in a `.tar.bz2`); summary
/// is a single GGUF used by llama.cpp. Nothing here talks to a server: the
/// bytes land in the app's own support directory and stay there.
class DeviceModel {
  const DeviceModel({
    required this.id,
    required this.kind,
    required this.label,
    required this.bytes,
    required this.url,
    this.detail = '',
  });

  final String id;
  final ModelKind kind;
  final String label;

  /// Download size, for the picker and for a progress bar before the server
  /// tells us the real length.
  final int bytes;
  final String url;

  /// One line of guidance under the chip.
  final String detail;

  bool get isBundle => kind == ModelKind.speech;

  /// File name while downloading and (for GGUFs) once installed.
  String get archiveName => isBundle ? '$id.tar.bz2' : '$id.gguf';

  /// Files that must exist for the model to count as installed.
  List<String> get requiredFiles => isBundle
      ? const ['encoder.int8.onnx', 'decoder.int8.onnx', 'tokens.txt']
      : ['$id.gguf'];

  /// Where the model lives: a directory for a whisper bundle, a file for a GGUF.
  String pathIn(String root) => isBundle ? '$root/$id' : '$root/$id.gguf';

  /// `1.1 GB` / `208 MB` — what the picker and the storage line show.
  static String sizeLabel(int bytes) => bytes >= 1000000000
      ? '${(bytes / 1000000000).toStringAsFixed(1)} GB'
      : '${(bytes / 1000000).round()} MB';
}

/// whisper sizes for the phone. `tiny` is the one to start with; `base` is the
/// best trade-off on a tablet; `small` is for a device you can leave alone.
const List<DeviceModel> deviceSpeechModels = [
  DeviceModel(
    id: 'whisper-tiny',
    kind: ModelKind.speech,
    label: 'tiny',
    bytes: 116204861,
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'sherpa-onnx-whisper-tiny.tar.bz2',
    detail: 'fastest, roughest — a few seconds for a short take',
  ),
  DeviceModel(
    id: 'whisper-base',
    kind: ModelKind.speech,
    label: 'base',
    bytes: 207557382,
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'sherpa-onnx-whisper-base.tar.bz2',
    detail: 'the balance most phones can keep up with',
  ),
  DeviceModel(
    id: 'whisper-small',
    kind: ModelKind.speech,
    label: 'small',
    bytes: 639387718,
    url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'sherpa-onnx-whisper-small.tar.bz2',
    detail: 'better with accents, slow on a phone — needs ~2 GB free to unpack',
  ),
];

/// Summary models small enough for a phone. A 3B+ GGUF is a PC model: the app
/// only offers these two, and the service keeps the bigger catalog.
const List<DeviceModel> deviceSummaryModels = [
  DeviceModel(
    id: 'qwen2.5-0.5b-instruct-q4_k_m',
    kind: ModelKind.summary,
    label: '0.5B',
    bytes: 491400032,
    url: 'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/'
        'qwen2.5-0.5b-instruct-q4_k_m.gguf',
    detail: 'small and quick; terse notes, occasionally misses an action',
  ),
  DeviceModel(
    id: 'qwen2.5-1.5b-instruct-q4_k_m',
    kind: ModelKind.summary,
    label: '1.5B',
    bytes: 1117320736,
    url: 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/'
        'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    detail: 'tighter notes and fewer misses; wants a tablet, not a small phone',
  ),
];

/// Progress of one download, in the shape the settings panel polls.
class ModelProgress {
  ModelProgress({
    this.state = 'idle',
    this.received = 0,
    this.total = 0,
    this.error,
    this.message,
  });

  /// `downloading`, `unpacking`, `done`, `error`, `cancelled`.
  String state;
  int received;
  int total;
  String? error;
  String? message;

  bool get finished => state == 'done' || state == 'error' || state == 'cancelled';

  /// `0..1`, or null when the length is not known yet.
  double? get fraction => total > 0 ? (received / total).clamp(0, 1) : null;

  String get label {
    if (state == 'unpacking') {
      return 'Unpacking…';
    }
    if (total > 0) {
      return '${(received / 1000000).toStringAsFixed(0)} / '
          '${(total / 1000000).toStringAsFixed(0)} MB';
    }
    return '${(received / 1000000).toStringAsFixed(0)} MB';
  }
}

/// Where on-device models live, and how they get there.
///
/// Separate from Flutter on purpose: the caller supplies [root], so the whole
/// download/unpack/delete path can be exercised in a plain test with a temp
/// directory and a `file://` URL.
class DeviceModels extends ChangeNotifier {
  DeviceModels(this.root);

  /// Directory holding installed models (created on demand).
  final Directory root;

  /// Downloads land here until they are complete.
  static const partialDirName = '.incoming';

  final Map<String, ModelProgress> _progress = {};
  final Map<String, _Download> _active = {};

  Directory get partialDir => Directory('${root.path}/$partialDirName');

  Future<void> init() => partialDir.create(recursive: true);

  static DeviceModel? byId(String id) {
    for (final m in [...deviceSpeechModels, ...deviceSummaryModels]) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// A GGUF may also be addressed by its bare stem (`qwen2.5-0.5b-instruct-q4_k_m`).
  static DeviceModel? byName(String name) =>
      byId(name) ??
      byId(name.endsWith('.gguf') ? name.substring(0, name.length - 5) : name);

  bool isInstalled(DeviceModel model) {
    for (final name in model.requiredFiles) {
      final f = File(model.isBundle
          ? '${model.pathIn(root.path)}/$name'
          : '${root.path}/$name');
      if (!f.existsSync()) {
        return false;
      }
    }
    return true;
  }

  List<DeviceModel> installed(ModelKind kind) => [
        for (final m in kind == ModelKind.speech ? deviceSpeechModels : deviceSummaryModels)
          if (isInstalled(m)) m,
      ];

  /// Bytes actually on disk, rounded to whole MB — the picker only needs scale.
  int installedBytes(DeviceModel model) {
    final path = model.pathIn(root.path);
    try {
      if (model.isBundle) {
        final dir = Directory(path);
        if (!dir.existsSync()) return 0;
        var total = 0;
        for (final f in dir.listSync(recursive: true).whereType<File>()) {
          total += f.lengthSync();
        }
        return total;
      }
      final f = File(path);
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  int get totalBytes {
    var total = 0;
    for (final m in [...deviceSpeechModels, ...deviceSummaryModels]) {
      total += installedBytes(m);
    }
    return total;
  }

  ModelProgress? progressOf(DeviceModel model) => _progress[model.id];

  /// Download (and unpack) [model]. Safe to call twice: the second call just
  /// watches the first.
  Future<void> download(DeviceModel model) async {
    if (isInstalled(model)) {
      _progress[model.id] = ModelProgress(state: 'done', received: model.bytes, total: model.bytes);
      notifyListeners();
      return;
    }
    if (_active.containsKey(model.id)) return;

    final task = _Download();
    _active[model.id] = task;
    final progress = _progress[model.id] = ModelProgress(total: model.bytes);
    notifyListeners();

    try {
      await init();
      final part = File('${partialDir.path}/${model.archiveName}');
      await part.parent.create(recursive: true);

      progress.state = 'downloading';
      notifyListeners();
      await task.fetch(model, part, (received, total) {
        progress.received = received;
        if (total > 0) progress.total = total;
        notifyListeners();
      });

      if (task.cancelled) throw const _Cancelled();
      if (model.bytes > 0 && part.lengthSync() != task.expected && task.expected > 0) {
        throw StateError('the download stopped early '
            '(${part.lengthSync()} of ${task.expected} bytes)');
      }

      if (model.isBundle) {
        progress.state = 'unpacking';
        notifyListeners();
        // bzip2 + tar are pure Dart but CPU-bound; keep them off the UI isolate.
        // Only strings cross the isolate boundary — File/Directory are not
        // sendable, and the model descriptor does not need to travel.
        final archivePath = part.path;
        final destination = model.pathIn(root.path);
        final wanted = List<String>.of(model.requiredFiles);
        await _unpackInIsolate(archivePath, destination, wanted);
      } else {
        final target = File(model.pathIn(root.path));
        if (target.existsSync()) target.deleteSync();
        await part.rename(target.path);
      }
      if (part.existsSync()) await part.delete();

      progress
        ..state = 'done'
        ..received = progress.total;
    } on _Cancelled {
      progress
        ..state = 'cancelled'
        ..error = 'Download cancelled';
      await _cleanupPartial(model);
    } catch (e) {
      progress
        ..state = 'error'
        ..error = '$e';
      await _cleanupPartial(model);
    } finally {
      _active.remove(model.id);
      notifyListeners();
    }
  }

  /// Stop a download in progress. The partial file is removed for you.
  void cancel(DeviceModel model) {
    _active[model.id]?.cancel();
    final progress = _progress[model.id];
    if (progress != null && !progress.finished) {
      progress.state = 'cancelled';
      progress.error = 'Download cancelled';
      notifyListeners();
    }
  }

  /// Remove an installed model; returns the bytes freed.
  Future<int> delete(DeviceModel model) async {
    final freed = installedBytes(model);
    final path = model.pathIn(root.path);
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    }
    await _cleanupPartial(model);
    _progress.remove(model.id);
    notifyListeners();
    return freed;
  }

  /// Unpacking runs in its own isolate, and the closure is built here rather
  /// than in [download] so it captures nothing but strings: a closure created in
  /// an instance method carries `this`, and a `ChangeNotifier` full of network
  /// state cannot cross an isolate boundary.
  static Future<void> _unpackInIsolate(
          String archivePath, String destination, List<String> wanted) =>
      Isolate.run(() => extractBundle(
            archivePath: archivePath,
            destination: destination,
            wanted: wanted,
          ));

  Future<void> _cleanupPartial(DeviceModel model) async {
    final part = File('${partialDir.path}/${model.archiveName}');
    try {
      if (part.existsSync()) await part.delete();
      final tmp = File('${part.path}.tar');
      if (tmp.existsSync()) await tmp.delete();
    } catch (_) {
      // A leftover partial file only costs space until the next attempt.
    }
  }

  @override
  void dispose() {
    for (final task in _active.values) {
      task.cancel();
    }
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Download {
  final http.Client _client = http.Client();
  final Completer<void> _done = Completer<void>();
  StreamSubscription<List<int>>? _sub;
  bool cancelled = false;

  /// Content length the server reported, so a truncated transfer is caught.
  int expected = 0;

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _sub?.cancel();
    // Cancelling a subscription does not fire onDone, so the awaiting side is
    // released here instead of waiting for a stream that will never end.
    if (!_done.isCompleted) _done.complete();
    _client.close();
  }

  Future<void> fetch(DeviceModel model, File part, void Function(int, int) onProgress) async {
    final request = http.Request('GET', Uri.parse(model.url));
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw StateError('the server answered ${response.statusCode}');
    }
    expected = response.contentLength ?? model.bytes;
    final sink = part.openWrite();
    var received = 0;
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    _sub = response.stream.listen(
      (chunk) {
        if (cancelled) return;
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReport) > const Duration(milliseconds: 250)) {
          lastReport = now;
          onProgress(received, expected);
        }
      },
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
      onError: (Object e, StackTrace s) {
        if (!_done.isCompleted) _done.completeError(e, s);
      },
      cancelOnError: true,
    );
    try {
      await _done.future;
      await sink.flush();
    } finally {
      await sink.close();
      _client.close();
    }
    onProgress(received, expected);
  }
}

/// Unpack the whisper files out of a sherpa-onnx `.tar.bz2`.
///
/// Top-level and isolate-friendly: the bz2 stream is inflated to a temporary tar
/// on disk (never fully in memory), and only the files in [wanted] are written
/// out, so unpacking `small` does not leave 1.4 GB of extra models behind.
///
/// Bundles name the same three files differently — `encoder.int8.onnx` in some
/// releases, `tiny-encoder.int8.onnx` in others — so a name matches when it ends
/// with the wanted one, and is then written under the canonical name. Everything
/// above (see `DeviceModel.requiredFiles`) expects the canonical names.
void extractBundle({
  required String archivePath,
  required String destination,
  required List<String> wanted,
}) {
  final tarPath = '$archivePath.tar';
  final bz2In = InputFileStream(archivePath);
  try {
    final tarOut = OutputFileStream(tarPath);
    BZip2Decoder().decodeStream(bz2In, tarOut, verify: true);
    tarOut.closeSync();
  } finally {
    bz2In.closeSync();
  }

  Directory(destination).createSync(recursive: true);
  final missing = wanted.toSet();
  final tarIn = InputFileStream(tarPath);
  try {
    TarDecoder().decodeStream(
      tarIn,
      verify: true,
      keepEntries: false,
      callback: (entry) {
        final name = entry.name.split('/').last;
        String? canonical;
        for (final candidate in missing) {
          if (name == candidate || name.endsWith('-$candidate')) {
            canonical = candidate;
            break;
          }
        }
        if (canonical == null) return;
        final out = OutputFileStream('$destination/$canonical');
        try {
          entry.writeContent(out);
        } finally {
          out.closeSync();
        }
        missing.remove(canonical);
      },
    );
  } finally {
    tarIn.closeSync();
    final tar = File(tarPath);
    if (tar.existsSync()) tar.deleteSync();
  }
  if (missing.isNotEmpty) {
    throw StateError('the archive is missing ${missing.join(', ')}');
  }
}
