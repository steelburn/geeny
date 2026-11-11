import 'dart:io';
import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';

/// Audio plumbing for on-device transcription.
///
/// The recorder writes **Ogg Opus, mono, 16 kHz**. whisper wants raw float
/// samples in [-1, 1] at 16 kHz, so the file is decoded by the platform's own
/// codecs (`audio_decoder` → MediaCodec on Android, AVFoundation on iOS) into a
/// temporary 16 kHz mono WAV, then parsed here. Decoding to a file rather than a
/// buffer keeps the native side's memory small and lets the heavy whisper step
/// live in its own isolate with nothing but a path to pass.
class DeviceAudio {
  DeviceAudio._();

  static const int sampleRate = 16000;

  /// Decode [source] to 16 kHz mono PCM and return the WAV file.
  ///
  /// The caller owns [workDir] and is expected to delete it afterwards — a
  /// ten-minute take is ~19 MB of 16-bit mono at this rate.
  static Future<File> decodeToPcm(File source, Directory workDir) async {
    await workDir.create(recursive: true);
    final out = File('${workDir.path}/pcm.wav');
    final path = await AudioDecoder.convertToWav(
      source.path,
      out.path,
      sampleRate: sampleRate,
      channels: 1,
      bitDepth: 16,
    );
    final decoded = File(path);
    if (!decoded.existsSync() || decoded.lengthSync() <= 44) {
      throw StateError('could not read audio from ${source.uri.pathSegments.last}');
    }
    return decoded;
  }

  /// The first channel of a RIFF/WAVE file as floats in [-1, 1].
  ///
  /// Handles the 16-bit PCM this app produces, plus 8-bit PCM and 32-bit float
  /// so a re-encoded file from another tool still works.
  static Float32List parseWav(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 44 || _ascii(bytes, 0, 4) != 'RIFF' || _ascii(bytes, 8, 4) != 'WAVE') {
      throw const FormatException('not a WAV file');
    }

    var format = 1;
    var channels = 1;
    var bits = 16;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = _ascii(bytes, offset, 4);
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        bits = data.getUint16(body + 14, Endian.little);
        if (format == 0xFFFE && body + 26 <= bytes.length) {
          // WAVE_FORMAT_EXTENSIBLE: the real format is in the first two bytes of
          // the sub-format GUID.
          format = data.getUint16(body + 24, Endian.little);
        }
      } else if (id == 'data') {
        final end = (body + size).clamp(body, bytes.length);
        return _samples(data, body, end, format, channels, bits);
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    throw const FormatException('the WAV file has no data chunk');
  }

  static Float32List _samples(
      ByteData data, int start, int end, int format, int channels, int bits) {
    final bytesPerSample = (bits / 8).ceil();
    if (bytesPerSample <= 0) throw const FormatException('bad sample width');
    final frame = bytesPerSample * (channels < 1 ? 1 : channels);
    final count = ((end - start) / frame).floor();
    final out = Float32List(count < 0 ? 0 : count);

    for (var i = 0; i < out.length; i++) {
      final at = start + i * frame; // channel 0 only; the recorder is mono anyway
      switch (bits) {
        case 8:
          out[i] = (data.getUint8(at) - 128) / 128.0;
        case 16:
          out[i] = data.getInt16(at, Endian.little) / 32768.0;
        case 24:
          final v = data.getUint8(at) | (data.getUint8(at + 1) << 8) | (data.getUint8(at + 2) << 16);
          out[i] = ((v & 0x800000) != 0 ? v - 0x1000000 : v) / 8388608.0;
        case 32:
          out[i] = format == 3
              ? data.getFloat32(at, Endian.little)
              : data.getInt32(at, Endian.little) / 2147483648.0;
        default:
          throw FormatException('unsupported sample width: $bits bits');
      }
    }
    return out;
  }

  static String _ascii(Uint8List bytes, int start, int length) =>
      String.fromCharCodes(bytes.sublist(start, start + length));
}
