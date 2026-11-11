import 'frame.dart';

/// Turns a notification byte stream into whole frames.
///
/// The device may send one frame per notification or split a large frame across
/// several. Rather than model that, resync on 0x55 and accept a frame only when
/// its length and checksum are valid.
class FrameAssembler {
  final List<int> _buf = [];

  List<Frame> feed(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <Frame>[];
    while (true) {
      final i = _buf.indexOf(start);
      if (i < 0) {
        _buf.clear();
        return out;
      }
      if (i > 0) _buf.removeRange(0, i);
      if (_buf.length < 17) return out;
      final total = 16 + (_buf[2] | (_buf[3] << 8));
      if (_buf.length < total + 1) return out;
      try {
        out.add(decode(_buf.sublist(0, total + 1)));
      } on FormatException {
        _buf.removeAt(0);
        continue;
      }
      _buf.removeRange(0, total + 1);
    }
  }

  void reset() => _buf.clear();
}
