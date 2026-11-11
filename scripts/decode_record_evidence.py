"""Timeline of a capture: what the vendor app writes around a recording.

    uv run python scripts/decode_record_evidence.py <btsnoop_hci.log> [--since HH:MM:SS]

Prints, in order: settings writes (channel 0x001e, TLV attr = value), file-channel
commands (0x8007, type/body) and identity/status reads. Anything the client does
not already write is flagged, so a vendor-app record start shows up immediately.
"""
from __future__ import annotations

import struct
import sys

sys.path.insert(0, "research")
import decode_btsnoop as D  # noqa: E402

KNOWN_ATTRS = {0x04, 0x0B, 0x11, 0x12, 0x13, 0x16, 0x17, 0x21}


def frames(path: str):
    pending: dict[tuple[int, int], bytearray] = {}
    for when, flags, data, _datalink in D.parse_records(path):
        if data[:1] != b"\x02" or len(data) < 5:
            continue
        direction = flags & 1
        key = (struct.unpack_from("<H", data, 1)[0] & 0x0FFF, direction)
        acl = data[5:]
        if len(acl) < 4:
            continue
        l2len, cid = struct.unpack_from("<HH", acl, 0)
        buf = pending.setdefault(key, bytearray())
        buf += acl[4 : 4 + l2len]
        if len(buf) < l2len:
            continue
        pkt, pending[key] = bytes(buf[:l2len]), bytearray()
        if cid == 4 and pkt[:1] in (b"\x1b", b"\x12", b"\x52") and len(pkt) > 3:
            yield when, direction, pkt[3:]


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    since = None
    if "--since" in sys.argv:
        since = sys.argv[sys.argv.index("--since") + 1]

    flagged = 0
    for when, direction, value in frames(path):
        stamp = when.strftime("%H:%M:%S.%f")[:-3]
        if since and stamp < since:
            continue
        if len(value) < 17 or value[0] != 0x55:
            continue
        length = int.from_bytes(value[2:4], "little")
        if len(value) < 17 + length:
            continue
        frame = value[: 17 + length]
        channel = int.from_bytes(frame[14:16], "little")
        payload = frame[16 : 16 + length]
        who = "HOST" if direction == 0 else "DEV "

        if channel == 0x001E and direction == 0 and len(payload) >= 3:
            attr, ln = payload[0], payload[1]
            val = payload[2 : 2 + ln]
            mark = "  <-- NEW" if attr not in KNOWN_ATTRS else ""
            print(f"{stamp} {who} settings  attr 0x{attr:02x} = {val.hex()}{mark}")
            flagged += bool(mark)
        elif channel == 0x8007 and len(payload) >= 10 and payload[0] == 0xAA:
            kind = payload[5]
            body_len = payload[6] | (payload[7] << 8)
            body = payload[8 : 8 + body_len]
            if kind in (0x82,) and len(body) >= 10:  # bulk: summarise
                seq = int.from_bytes(body[0:4], "little")
                off = int.from_bytes(body[4:8], "little")
                print(f"{stamp} {who} file      82 chunk seq={seq} off={off} len={body_len}")
            else:
                print(f"{stamp} {who} file      0x{kind:02x} body={body.hex()[:56]}")
        elif channel == 0x0015 and direction == 0:
            print(f"{stamp} {who} info      get_info")

    print(f"\n{flagged} unfamiliar settings write(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
