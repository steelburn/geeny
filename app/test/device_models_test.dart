import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/device/device_models.dart';

/// A `.tar.bz2` shaped like a sherpa-onnx whisper bundle: the three files the app
/// wants, plus the full-precision models it should not unpack. The real tiny
/// bundle prefixes every file (`tiny-encoder.int8.onnx`), so that is the default
/// here; `prefix: ''` covers releases that do not.
Uint8List whisperBundle({bool complete = true, String prefix = 'tiny-'}) {
  final archive = Archive();
  const folder = 'sherpa-onnx-whisper-tiny';
  archive.add(ArchiveFile.string('$folder/${prefix}encoder.int8.onnx', 'encoder'));
  archive.add(ArchiveFile.string('$folder/${prefix}decoder.int8.onnx', 'decoder'));
  if (complete) {
    archive.add(ArchiveFile.string('$folder/${prefix}tokens.txt', 'a\nb\n'));
  }
  archive.add(ArchiveFile.string('$folder/${prefix}encoder.onnx', 'x' * 1000));
  final tar = TarEncoder().encodeBytes(archive);
  return BZip2Encoder().encodeBytes(tar);
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('geeny-models');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('the catalog only offers models a phone can actually run', () {
    expect(deviceSpeechModels.map((m) => m.label), ['tiny', 'base', 'small']);
    expect(deviceSummaryModels.map((m) => m.label), ['0.5B', '1.5B']);
    for (final m in [...deviceSpeechModels, ...deviceSummaryModels]) {
      expect(m.url, startsWith('https://'));
      expect(m.bytes, greaterThan(10000000));
    }
    // A 3B GGUF is a PC model; it must not sneak into the on-device picker.
    expect(deviceSummaryModels.any((m) => m.label == '3B'), isFalse);
  });

  test('lookup works by id, by bare name and by file name', () {
    final tiny = deviceSpeechModels.first;
    expect(DeviceModels.byId('whisper-tiny'), tiny);
    expect(DeviceModels.byName('whisper-small')?.label, 'small');
    expect(DeviceModels.byName('qwen2.5-0.5b-instruct-q4_k_m')?.label, '0.5B');
    expect(DeviceModels.byName('qwen2.5-0.5b-instruct-q4_k_m.gguf')?.label, '0.5B');
    expect(DeviceModels.byId('gpt-4o'), isNull);
  });

  test('a bundle is a directory and a summary model is a file', () {
    final tiny = deviceSpeechModels.first;
    final gguf = deviceSummaryModels.first;
    expect(tiny.pathIn(root.path), '${root.path}/whisper-tiny');
    expect(tiny.requiredFiles, contains('encoder.int8.onnx'));
    expect(gguf.pathIn(root.path), '${root.path}/${gguf.id}.gguf');
    expect(gguf.requiredFiles, ['${gguf.id}.gguf']);
  });

  test('installed means every required file is there', () {
    final models = DeviceModels(root);
    final tiny = deviceSpeechModels.first;
    expect(models.isInstalled(tiny), isFalse);

    final dir = Directory(tiny.pathIn(root.path))..createSync(recursive: true);
    File('${dir.path}/encoder.int8.onnx').writeAsStringSync('x');
    File('${dir.path}/decoder.int8.onnx').writeAsStringSync('yy');
    expect(models.isInstalled(tiny), isFalse, reason: 'tokens.txt is still missing');

    File('${dir.path}/tokens.txt').writeAsStringSync('a\n');
    expect(models.isInstalled(tiny), isTrue);
    expect(models.installed(ModelKind.speech).single, tiny);
    expect(models.installedBytes(tiny), 5);
    expect(models.totalBytes, 5);
  });

  test('delete frees the model and reports what it freed', () async {
    final models = DeviceModels(root);
    final tiny = deviceSpeechModels.first;
    final dir = Directory(tiny.pathIn(root.path))..createSync(recursive: true);
    for (final name in tiny.requiredFiles) {
      File('${dir.path}/$name').writeAsStringSync('1234567890');
    }
    expect(models.totalBytes, 30);

    final freed = await models.delete(tiny);
    expect(freed, 30);
    expect(models.isInstalled(tiny), isFalse);
    expect(dir.existsSync(), isFalse);
    expect(models.totalBytes, 0);
  });

  test('unpacking keeps the three files and drops the rest', () async {
    final archive = File('${root.path}/whisper-tiny.tar.bz2')
      ..writeAsBytesSync(whisperBundle());
    final destination = '${root.path}/whisper-tiny';

    extractBundle(
      archivePath: archive.path,
      destination: destination,
      wanted: deviceSpeechModels.first.requiredFiles,
    );

    expect(File('$destination/encoder.int8.onnx').readAsStringSync(), 'encoder');
    expect(File('$destination/decoder.int8.onnx').readAsStringSync(), 'decoder');
    expect(File('$destination/tokens.txt').readAsStringSync(), 'a\nb\n');
    expect(File('$destination/encoder.onnx').existsSync(), isFalse,
        reason: 'the full-precision model would double the space for nothing');
    expect(File('${archive.path}.tar').existsSync(), isFalse,
        reason: 'the intermediate tar must not be left behind');
  });

  test('an incomplete archive fails loudly instead of installing half a model', () {
    final archive = File('${root.path}/whisper-tiny.tar.bz2')
      ..writeAsBytesSync(whisperBundle(complete: false));
    expect(
      () => extractBundle(
        archivePath: archive.path,
        destination: '${root.path}/whisper-tiny',
        wanted: deviceSpeechModels.first.requiredFiles,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('a bundle without the size prefix also installs, under the same names', () async {
    final archive = File('${root.path}/whisper-tiny.tar.bz2')
      ..writeAsBytesSync(whisperBundle(prefix: ''));
    final destination = '${root.path}/whisper-tiny';

    extractBundle(
      archivePath: archive.path,
      destination: destination,
      wanted: deviceSpeechModels.first.requiredFiles,
    );

    expect(File('$destination/encoder.int8.onnx').existsSync(), isTrue);
    expect(File('$destination/decoder.int8.onnx').existsSync(), isTrue);
    expect(File('$destination/tokens.txt').existsSync(), isTrue);
    expect(DeviceModels(root).isInstalled(deviceSpeechModels.first), isTrue);
  });

  test('sizes read the way the panel shows them', () {
    expect(DeviceModel.sizeLabel(116204861), '116 MB');
    expect(DeviceModel.sizeLabel(1117320736), '1.1 GB');
  });
}
