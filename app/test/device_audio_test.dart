import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geeny_app/ai/device/audio_io.dart';

/// A minimal RIFF/WAVE file with one channel of samples, so the parser can be
/// tested without a device, a plugin or a real decode.
Uint8List wavBytes({
  required int format,
  required int bits,
  required int channels,
  List<int> frames = const [],
  List<int>? rawData,
}) {
  final bytesPerSample = bits ~/ 8;
  final data = rawData ??
      [
        for (final f in frames)
          for (var i = 0; i < bytesPerSample; i++) (f >> (8 * i)) & 0xff,
      ];
  final dataSize = data.length;
  final out = BytesBuilder();
  void ascii(String s) => out.add(s.codeUnits);

  ascii('RIFF');
  out.add(_le32(36 + dataSize));
  ascii('WAVE');
  ascii('fmt ');
  out.add(_le32(16));
  out.add(_le16(format));
  out.add(_le16(channels));
  out.add(_le32(16000));
  out.add(_le32(16000 * channels * bytesPerSample));
  out.add(_le16(channels * bytesPerSample));
  out.add(_le16(bits));
  ascii('data');
  out.add(_le32(dataSize));
  out.add(data);
  return out.toBytes();
}

List<int> _le16(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> _le32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

void main() {
  test('16-bit PCM is read as floats in [-1, 1]', () {
    final samples = DeviceAudio.parseWav(wavBytes(
      format: 1,
      bits: 16,
      channels: 1,
      frames: [0, 16384, 32767, -32768, -16384],
    ));
    expect(samples.length, 5);
    expect(samples[0], 0);
    expect(samples[1], closeTo(0.5, 0.001));
    expect(samples[2], closeTo(0.99997, 0.001));
    expect(samples[3], -1);
    expect(samples[4], closeTo(-0.5, 0.001));
  });

  test('stereo takes the first channel, as playback does', () {
    final samples = DeviceAudio.parseWav(wavBytes(
      format: 1,
      bits: 16,
      channels: 2,
      frames: [16384, -16384, -32768, 32767],
    ));
    expect(samples.length, 2);
    expect(samples[0], closeTo(0.5, 0.001));
    expect(samples[1], -1);
  });

  test('8-bit unsigned PCM is centred on 128', () {
    final samples = DeviceAudio.parseWav(wavBytes(
      format: 1,
      bits: 8,
      channels: 1,
      frames: [128, 255, 0],
    ));
    expect(samples[0], 0);
    expect(samples[1], closeTo(0.99, 0.01));
    expect(samples[2], -1);
  });

  test('32-bit float PCM is passed through', () {
    final floats = <int>[];
    for (final v in [0.25, -0.75]) {
      final b = ByteData(4)..setFloat32(0, v, Endian.little);
      floats.addAll(b.buffer.asUint8List());
    }
    final samples = DeviceAudio.parseWav(wavBytes(
      format: 3,
      bits: 32,
      channels: 1,
      rawData: floats,
    ));
    expect(samples[0], closeTo(0.25, 0.0001));
    expect(samples[1], closeTo(-0.75, 0.0001));
  });

  test('a file that is not a WAV is rejected, not silently zeroed', () {
    expect(
      () => DeviceAudio.parseWav(Uint8List.fromList('not audio at all, really'.codeUnits)),
      throwsFormatException,
    );
  });

  test('a WAV with no data chunk is rejected', () {
    final bytes = wavBytes(format: 1, bits: 16, channels: 1, frames: const [])
        .sublist(0, 36);
    expect(() => DeviceAudio.parseWav(bytes), throwsFormatException);
  });
}
