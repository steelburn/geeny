// CRC16 for the device's attribute/TLV layer.
// Tables extracted from the vendor SDK (libcfdlink.so @ 0x1a825 / 0x1a925).
// Verified against device replies and app writes:
//   name reply c9 64 | sn reply f0 05 | gain 18 dB write c0 5c | attr 0x12 write 60 55
// Generated from notra/crc.py - keep the two in sync.

const String _loHex =
    '00c1814001c0804101c0804100c1814001c0804100c1814000c1814001c0804101c0804100c1814000c1814001c08041'
    '00c1814001c0804101c0804100c1814001c0804100c1814000c1814001c0804100c1814001c0804101c0804100c18140'
    '00c1814001c0804101c0804100c1814001c0804100c1814000c1814001c0804101c0804100c1814000c1814001c08041'
    '00c1814001c0804101c0804100c1814000c1814001c0804101c0804100c1814001c0804100c1814000c1814001c08041'
    '00c1814001c0804101c0804100c1814001c0804100c1814000c1814001c0804101c0804100c1814000c1814001c08041'
    '00c1814001c0804101c0804100c18140';

const String _hiHex =
    '00c0c101c30302c2c60607c705c5c404cc0c0dcd0fcfce0e0acacb0bc90908c8d81819d91bdbda1a1ededf1fdd1d1cdc'
    '14d4d515d71716d6d21213d311d1d010f03031f133f3f23236f6f737f53534f43cfcfd3dff3f3efefa3a3bfb39f9f838'
    '28e8e929eb2b2aeaee2e2fef2dedec2ce42425e527e7e62622e2e323e12120e0a06061a163a3a26266a6a767a56564a4'
    '6cacad6daf6f6eaeaa6a6bab69a9a86878b8b979bb7b7ababe7e7fbf7dbdbc7cb47475b577b7b67672b2b373b17170b0'
    '509091519353529296565797559594549c5c5d9d5f9f9e5e5a9a9b5b99595898884849894b8b8a4a4e8e8f4f8d4d4c8c'
    '44848545874746868242438341818040';

final List<int> _lo = _hexToBytes(_loHex);
final List<int> _hi = _hexToBytes(_hiHex);

List<int> _hexToBytes(String s) {
  final out = List<int>.filled(s.length ~/ 2, 0);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Non-standard CRC16 the device uses for attributes and file framing.
int crc16(List<int> data) {
  var c = 0;
  for (final b in data) {
    final i = (c ^ b) & 0xff;
    c = ((c >> 8) ^ (_hi[i] << 8) ^ _lo[i]) & 0xffff;
  }
  return c;
}

/// Little-endian CRC16 as the wire expects it.
List<int> crc16Bytes(List<int> data) {
  final c = crc16(data);
  return [c & 0xff, (c >> 8) & 0xff];
}

final List<int> _crc32Table = List<int>.generate(256, (i) {
  var c = i;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// zlib CRC32, used inside file-channel frames.
int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crc32Table[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
