"""Decode Android btsnoop_hci.log -> BLE ATT operations -> Boya frames.

Usage:
  python research/decode_btsnoop.py <btsnoop_hci.log> [--all] [--since HH:MM:SS]

Default output: only ATT traffic on connections that carry 0x55-framed Boya data
(--all shows every ATT op). Frames are decoded with the layout recovered from
libcfdlink.so: 55 | flags|0x10 | len u16le | 12B cmd/attr | payload | sum8
"""
from __future__ import annotations

import struct
import sys
from datetime import datetime, timedelta

EPOCH_0AD = datetime(1, 1, 1)

ATT_WRITE_REQ = 0x12
ATT_WRITE_CMD = 0x52
ATT_NOTIFY = 0x1B
ATT_INDICATE = 0x1D
ATT_READ_REQ = 0x0A
ATT_READ_RSP = 0x0B


def parse_records(path: str):
    raw = open(path, "rb").read()
    if raw[:8] != b"btsnoop\x00":
        raise SystemExit("not a btsnoop file")
    datalink = struct.unpack(">I", raw[12:16])[0]
    off, n = 16, len(raw)
    while off + 24 <= n:
        orig, incl, flags, drops = struct.unpack(">IIII", raw[off : off + 16])
        ts = struct.unpack(">Q", raw[off + 16 : off + 24])[0]
        data = raw[off + 24 : off + 24 + incl]
        off += 24 + incl
        # Android: timestamp is microseconds since 0 AD
        when = EPOCH_0AD + timedelta(microseconds=ts)
        yield when, flags, data, datalink


def decode_frames(payload: bytes) -> str:
    """Decode a Boya CFDLink frame (best effort) into readable field names."""
    if len(payload) < 17 or payload[0] != 0x55:
        return "not a Boya frame"
    ln = payload[2] | (payload[3] << 8)
    body = payload[16 : 16 + ln]
    total = 16 + ln
    cks = payload[total] if len(payload) > total else None
    calc = sum(payload[:total]) & 0xFF
    ok = "" if cks is None else ("  CHECKSUM OK" if cks == calc else f"  CHECKSUM BAD got={cks:02x} want={calc:02x}")
    return (
        f"len={ln} flags={payload[1]:02x} key={payload[4:16].hex()} "
        f"payload({ln})={body.hex()}{ok}"
    )


def main() -> None:
    path = sys.argv[1]
    show_all = "--all" in sys.argv
    since = None
    if "--since" in sys.argv:
        t = sys.argv[sys.argv.index("--since") + 1]
        hh, mm, ss = (int(x) for x in t.split(":"))
        now = datetime.now()
        since = now.replace(hour=hh, minute=mm, second=ss, microsecond=0)

    handles: dict[int, str] = {}          # handle -> address
    att_handles: set[int] = set()         # handles seen carrying 0x55 frames
    pending: dict[int, bytearray] = {}     # handle -> l2cap assembly
    rows = 0

    for when, flags, data, datalink in parse_records(path):
        if since and when < since:
            continue
        if not data:
            continue
        pkt_type = data[0]

        # LE Connection Complete (event 0x3e, subevent 0x01)
        if pkt_type == 0x04 and len(data) >= 20 and data[1] == 0x3E and data[3] == 0x01:
            h = struct.unpack_from("<H", data, 4)[0] & 0x0FFF
            addr = ":".join(f"{b:02X}" for b in reversed(data[8:14]))
            handles[h] = addr
            print(f"{when:%H:%M:%S.%f} [CONNECT] handle=0x{h:03x} peer={addr}")
            continue

        if pkt_type != 0x02:  # only ACL data
            continue
        if len(data) < 5:
            continue
        hci_h = struct.unpack_from("<H", data, 1)[0]
        handle = hci_h & 0x0FFF
        acl = data[5:]
        if len(acl) < 4:
            continue
        l2_len, cid = struct.unpack_from("<HH", acl, 0)
        frag = acl[4 : 4 + l2_len]

        buf = pending.setdefault(handle, bytearray())
        buf += frag
        if len(buf) < l2_len:
            continue
        packet, pending[handle] = bytes(buf[:l2_len]), bytearray()
        if cid != 0x0004 or len(packet) < 3:
            continue  # not ATT

        op = packet[0]
        ch = struct.unpack_from("<H", packet, 1)[0] if len(packet) >= 3 else 0
        val = packet[3:]
        direction = "TX(host->dev)" if flags & 1 == 0 else "RX(dev->host)"

        interesting = op in (ATT_WRITE_CMD, ATT_WRITE_REQ, ATT_NOTIFY, ATT_INDICATE, ATT_READ_REQ, ATT_READ_RSP)
        if not interesting and not show_all:
            continue
        if val[:1] == b"\x55":
            att_handles.add(ch)
        if not show_all and ch not in att_handles:
            continue

        who = handles.get(handle, f"0x{handle:03x}")
        label = {
            ATT_WRITE_CMD: "WRITE-CMD", ATT_WRITE_REQ: "WRITE-REQ",
            ATT_NOTIFY: "NOTIFY", ATT_INDICATE: "INDICATE",
            ATT_READ_REQ: "READ-REQ", ATT_READ_RSP: "READ-RSP",
        }.get(op, f"op0x{op:02x}")
        rows += 1
        line = f"{when:%H:%M:%S.%f} {who} {label:9s} chr=0x{ch:04x} {direction} {val.hex()}"
        extra = decode_frames(val) if direction.startswith("TX") or op in (ATT_NOTIFY, ATT_INDICATE) else ""
        print(f"{line}\n                            -> {extra}" if extra else line)

    print(f"\n{rows} ATT row(s); connections: {handles or 'none'}")


if __name__ == "__main__":
    main()
