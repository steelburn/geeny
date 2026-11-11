import 'dart:io';

import 'package:flutter/services.dart';

/// A file handed to Geeny by the Android share sheet or the system file picker.
///
/// Boya OS shares and exports files rather than exposing an API, so this is the
/// interoperability surface: share a recording or a transcript from that app and
/// Geeny can keep it. Nothing is uploaded anywhere.
class SharedFile {
  const SharedFile({
    required this.path,
    required this.name,
    required this.mime,
    required this.size,
  });

  /// A copy inside the app's cache, readable by Dart.
  final String path;
  final String name;
  final String mime;
  final int size;

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// Containers the import accepts, matching what `MainActivity` copies out of a
  /// content URI. `Take.audioExtensions` is this same set: a file the share
  /// sheet accepts but the library will not list is an import that vanishes.
  static const audioExtensions = {
    'ogg', 'opus', 'oga', 'wav', 'mp3', 'm4a', 'flac', 'aac', 'amr',
  };
  static const _text = {'json', 'txt', 'md', 'markdown', 'srt'};

  bool get isAudio => audioExtensions.contains(extension) || mime.startsWith('audio/');
  bool get isText => _text.contains(extension) || mime.startsWith('text/') || mime == 'application/json';

  /// True for the formats the local service can decode without extra tooling.
  bool get transcribable => const {'ogg', 'opus', 'oga', 'wav', 'flac'}.contains(extension);

  static SharedFile? fromMap(dynamic map) {
    if (map is! Map) return null;
    final path = (map['path'] ?? '').toString();
    if (path.isEmpty || !File(path).existsSync()) return null;
    return SharedFile(
      path: path,
      name: (map['name'] ?? File(path).uri.pathSegments.last).toString(),
      mime: (map['mime'] ?? '').toString(),
      size: (map['size'] as num?)?.toInt() ?? File(path).lengthSync(),
    );
  }
}

/// The bridge to `MainActivity`, which registers Geeny as a share target and can
/// open the system file picker.
class ShareIn {
  ShareIn._();

  static const _channel = MethodChannel('dev.geeny.app/share');

  /// Whether the platform side exists (Android only; the app is Android-only, but
  /// unit tests run on the host).
  static bool get supported => Platform.isAndroid;

  /// A share that started the app, if any. Answered once, then cleared.
  static Future<SharedFile?> initial() async {
    if (!supported) return null;
    try {
      final value = await _channel.invokeMethod<dynamic>('initial');
      return SharedFile.fromMap(value);
    } catch (_) {
      return null;
    }
  }

  /// Open the system picker and copy whatever is chosen into the cache.
  static Future<SharedFile?> pick() async {
    if (!supported) return null;
    try {
      final value = await _channel.invokeMethod<dynamic>('pick');
      return SharedFile.fromMap(value);
    } catch (_) {
      return null;
    }
  }

  /// Shares that arrive while the app is running (`singleTop` relaims the intent).
  static void listen(void Function(SharedFile file) onShared) {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'shared') return null;
      final file = SharedFile.fromMap(call.arguments);
      if (file != null) onShared(file);
      return null;
    });
  }
}
