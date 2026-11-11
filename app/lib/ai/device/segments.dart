/// Turns whisper's token timings into the segments the app shows.
///
/// Pure functions only: this is the part of on-device transcription that can be
/// unit-tested without a model, a device or a plugin.
library;

final RegExp _specialToken = RegExp(r'^<\|.*\|>$');
final RegExp _sentenceEnd = RegExp(r'''[.!?…]["'’”)\]]?$''');

double _round(double v) => (v * 100).roundToDouble() / 100;

String _squeeze(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Segments for one whisper result.
///
/// [tokens] and [timestamps] are whisper's BPE pieces and their start times (in
/// seconds); [text] is the recogniser's own full transcript. Whisper normally
/// gives both, and the tokens are used for the clock. When a build returns only
/// a handful of tokens, or pieces that do not rejoin into [text], the words of
/// [text] are spread across the same time span instead so a transcript never
/// ends up untimestamped.
///
/// Break rules: a pause longer than [pauseBreak], a sentence end followed by any
/// pause at all, or [maxSegment] seconds — whichever comes first.
List<Map<String, dynamic>> buildSegments({
  required List<String> tokens,
  required List<double> timestamps,
  required String text,
  required double duration,
  double pauseBreak = 0.9,
  double punctuationBreak = 0.25,
  double maxSegment = 15,
}) {
  final pieces = <({String text, double at})>[];
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token.isEmpty || _specialToken.hasMatch(token)) continue;
    final at = i < timestamps.length
        ? timestamps[i]
        : (pieces.isEmpty ? 0.0 : pieces.last.at);
    pieces.add((text: token, at: at));
  }

  final clean = _squeeze(text);
  final joined = _squeeze(pieces.map((p) => p.text).join());
  final tokensMatchText = pieces.isNotEmpty && joined == clean;

  if (!tokensMatchText) return _wordTimed(text: clean, timestamps: timestamps, duration: duration);

  final out = <Map<String, dynamic>>[];
  final buffer = StringBuffer();
  var start = pieces.first.at;
  var last = start;

  void flush() {
    final body = _squeeze(buffer.toString());
    if (body.isEmpty) return;
    out.add({'start': _round(start), 'end': _round(last + 0.4), 'text': body});
    buffer.clear();
  }

  for (final piece in pieces) {
    if (buffer.isEmpty) {
      start = piece.at;
    } else {
      final gap = piece.at - last;
      final endsSentence = _sentenceEnd.hasMatch(_squeeze(buffer.toString()));
      if (gap > pauseBreak ||
          (gap > punctuationBreak && endsSentence) ||
          piece.at - start > maxSegment) {
        flush();
        start = piece.at;
      }
    }
    buffer.write(piece.text);
    last = piece.at;
  }
  flush();
  return _clamp(out, duration);
}

/// Spread [text]'s words over the recognised time span, one segment per
/// sentence. Used when token pieces cannot be trusted to rebuild the text.
List<Map<String, dynamic>> _wordTimed({
  required String text,
  required List<double> timestamps,
  required double duration,
}) {
  if (text.isEmpty) return const [];
  final words = text.split(' ');
  final spanStart = timestamps.isEmpty ? 0.0 : timestamps.first;
  // The audio's own length is a better end than the last timing we happen to
  // have: these tokens were not usable, so their clock is not either.
  final spanEnd = duration > spanStart
      ? duration
      : timestamps.isEmpty
          ? spanStart + words.length * 0.4
          : timestamps.last + 0.4;
  final span = spanEnd > spanStart ? spanEnd - spanStart : words.length * 0.4;
  double at(int index) => spanStart + span * (index / (words.isEmpty ? 1 : words.length));

  final out = <Map<String, dynamic>>[];
  var firstWord = 0;
  for (var i = 0; i < words.length; i++) {
    final isLast = i == words.length - 1;
    if (!isLast && !_sentenceEnd.hasMatch(words[i])) continue;
    final body = words.sublist(firstWord, i + 1).join(' ');
    if (body.trim().isNotEmpty) {
      out.add({
        'start': _round(at(firstWord)),
        'end': _round(at(i + 1)),
        'text': body,
      });
    }
    firstWord = i + 1;
  }
  return _clamp(out, duration);
}

List<Map<String, dynamic>> _clamp(List<Map<String, dynamic>> segments, double duration) {
  if (duration <= 0) return segments;
  for (final s in segments) {
    final start = s['start'] as double;
    if (start > duration) s['start'] = duration;
    if ((s['end'] as double) > duration) s['end'] = duration;
    if ((s['end'] as double) < (s['start'] as double)) s['end'] = s['start'];
  }
  return segments;
}
