"""Extract the audio file from a captured btsnoop log (correct ACL reassembly).

Device streams file content as 0x55 frames on key 19 00 01 02 25 ... ; each payload is:

    0        aa  (chunk sync)
    1..4     crc32 of the chunk data
    5        82  (chunk type)
    6..7     34 08 (constant)
    8..11    sequence u32
    12..15   file offset u32
    16..17   chunk data length u16
    18..     data
    last 2   crc16 of the chunk

Usage: python research/extract_file.py <btsnoop_hci.log> <out.ogg>
"""
import struct
import sys
from datetime import datetime, timedelta

EPOCH_0AD = datetime(1, 1, 1)
DATA_KEY = bytes.fromhex("1900010225")


def records(path):
    raw = open(path, "rb").read()
    off, n = 16, len(raw)
    while off + 24 <= n:
        incl = struct.unpack(">I", raw[off + 4 : off + 8])[0]
        ts = struct.unpack(">Q", raw[off + 16 : off + 24])[0]
        data = raw[off + 24 : off + 24 + incl]
        off += 24 + incl
        yield EPOCH_0AD + timedelta(microseconds=ts), data


def att_notifications(path):
    """Reassemble L2CAP PDUs honouring the ACL PB flag, then emit ATT notifications."""
    pdu = {}
    for when, data in records(path):
        if not data or data[0] != 0x02 or len(data) < 5:
            continue
        hdr = struct.unpack_from("<H", data, 1)[0]
        handle, pb = hdr & 0x0FFF, (hdr >> 12) & 0x3
        payload = data[5:]

        if pb == 0b10:  # start of a new L2CAP PDU
            if len(payload) < 4:
                continue
            pdu[handle] = bytearray(payload)
        elif pb == 0b01:  # continuation
            if handle not in pdu:
                continue
            pdu[handle] += payload
        else:
            continue

        buf = pdu.get(handle)
        if buf is None or len(buf) < 4:
            continue
        l2len, cid = struct.unpack_from("<HH", buf, 0)
        if len(buf) < 4 + l2len:
            continue  # wait for more fragments
        pkt = bytes(buf[4 : 4 + l2len])
        pdu[handle] = bytearray()
        if cid == 0x0004 and len(pkt) > 3 and pkt[0] == 0x1B:
            yield when, pkt[3:]


def main() -> None:
    src, out = sys.argv[1], sys.argv[2]
    chunks = {}
    for when, val in att_notifications(src):
        if len(val) < 20 or val[0] != 0x55:
            continue
        if not val[4:9].startswith(DATA_KEY):
            continue
        pay = val[16 : 16 + (val[2] | (val[3] << 8))]
        if len(pay) < 20 or pay[0] != 0xAA:
            continue
        seq, offset, dlen = struct.unpack_from("<IIH", pay, 8)
        data = pay[18 : 18 + dlen]
        if len(data) != dlen:
            print(f"  ! short chunk seq={seq} want={dlen} got={len(data)}")
            continue
        chunks[offset] = data

    if not chunks:
        sys.exit("no file-data chunks found")

    offsets = sorted(chunks)
    total = sum(len(v) for v in chunks.values())
    print(f"{len(chunks)} chunks, offsets {offsets[0]}..{offsets[-1]}, {total} bytes")
    gaps = [b - a - len(chunks[a]) for a, b in zip(offsets, offsets[1:])]
    print("offset gaps (all 0 = contiguous):", set(gaps))

    body = b"".join(chunks[o] for o in offsets)
    open(out, "wb").write(body)
    print(f"wrote {out}: {len(body)} bytes")
    print("magic:", body[:4], "|", "Ogg" if body[:4] == b"OggS" else "unknown")
    print("pages (OggS count):", body.count(b"OggS"))
    i = body.find(b"OpusHead")
    if i > 0:
        ch = body[i + 9]
        rate = struct.unpack_from("<I", body, i + 12)[0]
        print(f"OpusHead: channels={ch} rate={rate}")


if __name__ == "__main__":
    main()
