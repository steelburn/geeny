import 'dart:typed_data';

/// Length of an audio file read from its own container headers.
///
/// The library holds more than the Ogg the recorder writes: an import from Boya
/// OS can arrive as MP3, WAV or FLAC. Reading the length here — before anything
/// is played — keeps the takes list honest for every format it lists.
///
/// Formats whose length needs a decoder (M4A/AAC/AMR) return `null` instead of a
/// guess, and the row shows `--:--`.
Duration? audioDuration(Uint8List bytes, String extension) =>
    switch (extension.toLowerCase()) {
      'ogg' || 'oga' || 'opus' => oggDuration(bytes),
      'mp3' || 'mp2' || 'mpga' => mp3Duration(bytes),
      'wav' || 'wave' => wavDuration(bytes),
      'flac' => flacDuration(bytes),
      _ => null,
    };

// --- Ogg Opus ---------------------------------------------------------------

/// Ogg Opus length from the last page's granule position (48 kHz).
///
/// Ogg defines the duration by the final page, not by the largest granule: one
/// damaged or odd page in the middle can carry a nonsense value, and taking the
/// maximum would report a 48 s take as three hours.
///
/// The granule counts 48 kHz samples whatever the Opus stream's own rate is
/// (RFC 7845 §4), so a 16 kHz mono take's granule is still 48 000 per second.
/// Dividing by 16 made every recording read three times too long.
Duration? oggDuration(Uint8List bytes) {
  var lastGranule = 0;
  var maxGranule = 0;
  var seen = 0;
  var i = 0;
  while (true) {
    final idx = _findOggS(bytes, i);
    if (idx < 0 || idx + 27 > bytes.length) break;
    final granule = bytes[idx + 6] |
        (bytes[idx + 7] << 8) |
        (bytes[idx + 8] << 16) |
        (bytes[idx + 9] << 24);
    if (granule > maxGranule) maxGranule = granule;
    lastGranule = granule;
    seen++;
    final nseg = bytes[idx + 26];
    var body = 0;
    for (var k = 0; k < nseg && idx + 27 + k < bytes.length; k++) {
      body += bytes[idx + 27 + k];
    }
    i = idx + 27 + nseg + body;
  }
  if (seen == 0) return null;
  final use = lastGranule > 0 ? lastGranule : maxGranule;
  if (use <= 0) return null;
  return Duration(milliseconds: (use / 48).round());
}

int _findOggS(Uint8List b, int from) {
  for (var i = from; i + 4 <= b.length; i++) {
    if (b[i] == 0x4F && b[i + 1] == 0x67 && b[i + 2] == 0x67 && b[i + 3] == 0x53) return i;
  }
  return -1;
}

// --- WAV --------------------------------------------------------------------

/// RIFF/WAVE length from the `fmt ` byte rate and the `data` chunk size.
Duration? wavDuration(Uint8List bytes) {
  if (bytes.length < 44 || _ascii(bytes, 0, 4) != 'RIFF' || _ascii(bytes, 8, 4) != 'WAVE') {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  var byteRate = 0;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = _ascii(bytes, offset, 4);
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ' && body + 12 <= bytes.length) {
      byteRate = data.getUint32(body + 8, Endian.little);
    } else if (id == 'data') {
      if (byteRate <= 0) return null;
      // A streamed file writes 0 or 0xFFFFFFFF when the size was unknown up
      // front; the rest of the file is the data then.
      final end = size == 0 || size > bytes.length - body ? bytes.length : body + size;
      return Duration(milliseconds: (end - body) * 1000 ~/ byteRate);
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

// --- FLAC -------------------------------------------------------------------

/// FLAC length from the STREAMINFO block's sample rate and sample count.
Duration? flacDuration(Uint8List bytes) {
  if (bytes.length < 26 || _ascii(bytes, 0, 4) != 'fLaC') return null;
  if ((bytes[4] & 0x7F) != 0) return null; // the first block is always STREAMINFO
  final data = ByteData.sublistView(bytes);
  final high = data.getUint32(18);
  final low = data.getUint32(22);
  final sampleRate = high >> 12; // 20 bits
  final totalSamples = ((high & 0x0FFF) << 32) | low; // 36 bits
  if (sampleRate == 0 || totalSamples == 0) return null;
  return Duration(milliseconds: totalSamples * 1000 ~/ sampleRate);
}

// --- MP3 --------------------------------------------------------------------

const _bitrates = <int, List<int>>{
  // key: (mpeg1 ? 0 : 1) * 3 + layer  (layer 1..3, not the header's 3..1)
  3 + 1: [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
  3 + 2: [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
  3 + 3: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
  1: [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
  2: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
  3: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
};

const _sampleRates = <int, List<int>>{
  3: [44100, 48000, 32000], // MPEG 1
  2: [22050, 24000, 16000], // MPEG 2
  0: [11025, 12000, 8000], // MPEG 2.5
};

class _Mp3Frame {
  const _Mp3Frame({
    required this.length,
    required this.samples,
    required this.sampleRate,
    required this.bitrate,
    required this.mono,
  });

  /// Whole frame in bytes, header included.
  final int length;

  /// PCM samples per channel this frame carries.
  final int samples;
  final int sampleRate;

  /// kbit/s.
  final int bitrate;
  final bool mono;
}

_Mp3Frame? _mp3Frame(Uint8List b, int at) {
  if (at < 0 || at + 4 > b.length) return null;
  if (b[at] != 0xFF || (b[at + 1] & 0xE0) != 0xE0) return null;
  final version = (b[at + 1] >> 3) & 0x03; // 3 = MPEG 1, 2 = MPEG 2, 0 = 2.5
  final layerBits = (b[at + 1] >> 1) & 0x03; // 3 = I, 2 = II, 1 = III
  final bitrateIndex = (b[at + 2] >> 4) & 0x0F;
  final rateIndex = (b[at + 2] >> 2) & 0x03;
  if (version == 1 || layerBits == 0 || bitrateIndex == 0 || bitrateIndex == 15) return null;
  if (rateIndex == 3) return null;
  final rates = _sampleRates[version];
  if (rates == null) return null;
  final sampleRate = rates[rateIndex];
  final layer = 4 - layerBits; // 1..3, the order people use
  final table = _bitrates[(version == 3 ? 3 : 0) + layer];
  if (table == null) return null;
  final bitrate = table[bitrateIndex];
  final padding = (b[at + 2] >> 1) & 0x01;
  final samples = switch (layer) {
    1 => 384,
    2 => 1152,
    _ => version == 3 ? 1152 : 576,
  };
  // 144 for Layer II/III at MPEG 1, 72 for Layer III at MPEG 2/2.5, 48 for Layer I.
  final coefficient = switch (layer) {
    1 => 48,
    2 => 144,
    _ => version == 3 ? 144 : 72,
  };
  final length = (coefficient * bitrate * 1000 ~/ sampleRate) + padding;
  if (length < 4) return null;
  return _Mp3Frame(
    length: length,
    samples: samples,
    sampleRate: sampleRate,
    bitrate: bitrate,
    mono: ((b[at + 3] >> 6) & 0x03) == 3,
  );
}

/// MP3 length: the Xing/Info frame count when the encoder wrote one, otherwise
/// every frame is walked (which is also right for VBR without a Xing header).
Duration? mp3Duration(Uint8List bytes) {
  var start = 0;
  // ID3v2 tag in front: syncsafe 28-bit size at bytes 6..9.
  if (bytes.length >= 10 && _ascii(bytes, 0, 3) == 'ID3') {
    start = 10 +
        ((bytes[6] & 0x7F) << 21) +
        ((bytes[7] & 0x7F) << 14) +
        ((bytes[8] & 0x7F) << 7) +
        (bytes[9] & 0x7F);
  }
  var end = bytes.length;
  // ID3v1 tag at the back is not audio.
  if (end >= 128 && _ascii(bytes, end - 128, 3) == 'TAG') end -= 128;
  if (start >= end) return null;

  final first = _firstFrame(bytes, start);
  if (first == null) return null;
  final (at, frame) = first;

  final xing = _xingFrameCount(bytes, at, frame);
  if (xing != null && xing > 0) {
    return Duration(milliseconds: xing * frame.samples * 1000 ~/ frame.sampleRate);
  }

  var frames = 0;
  var offset = at;
  while (offset < end) {
    final header = _mp3Frame(bytes, offset);
    if (header == null) break;
    frames++;
    offset += header.length;
  }
  if (frames > 0) {
    return Duration(milliseconds: frames * frame.samples * 1000 ~/ frame.sampleRate);
  }

  // Nothing but the first header was readable: fall back to the bitrate, which
  // is only exact for CBR but still better than "unknown".
  final audioBytes = end - at;
  return Duration(milliseconds: audioBytes * 8 ~/ frame.bitrate);
}

/// First position in `[from, min(from + 64k, end))` where two frames in a row
/// parse — one 11-bit sync word alone is far too common inside audio data.
(int, _Mp3Frame)? _firstFrame(Uint8List bytes, int from) {
  final limit = (from + 64 * 1024).clamp(0, bytes.length);
  for (var i = from; i + 4 <= limit; i++) {
    final frame = _mp3Frame(bytes, i);
    if (frame == null) continue;
    final next = _mp3Frame(bytes, i + frame.length);
    if (next != null) return (i, frame);
    // A short last frame can be the only one; accept a lone header at the very
    // start of the audio, where a tag cannot hide it.
    if (i == from) return (i, frame);
  }
  return null;
}

/// Frame count from a Xing/Info header in the first frame, if one is there.
int? _xingFrameCount(Uint8List bytes, int at, _Mp3Frame frame) {
  final sideInfo = frame.mono ? 17 : 32;
  final tag = at + 4 + sideInfo;
  if (tag + 12 > bytes.length) return null;
  final id = _ascii(bytes, tag, 4);
  if (id != 'Xing' && id != 'Info') return null;
  final flags = ByteData.sublistView(bytes).getUint32(tag + 4);
  if (flags & 0x01 == 0) return null;
  return ByteData.sublistView(bytes).getUint32(tag + 8);
}

String _ascii(Uint8List bytes, int start, int length) =>
    String.fromCharCodes(bytes.sublist(start, start + length));
