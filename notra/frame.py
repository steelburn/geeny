"""CFDLink frame layer for the Boya Notra Neo.

Layout (verified on 952 live frames, see research/PROTOCOL.md):

    0        0x55
    1        flags         0x10 status/ack | 0x11 data response | 0x12 request
    2..3     payload length, u16 LE
    4..15    routing key: [msgId u16][src 4][dst 4][channel u16]
    16..     payload
    16+len   8-bit sum of all preceding bytes   (total = len + 17)
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

START = 0x55

FLAG_STATUS = 0x10
FLAG_DATA = 0x11
FLAG_REQUEST = 0x12

# routing nodes (from the capture)
APP_NODE = bytes.fromhex("01011d00")
DEV_NODE = bytes.fromhex("01022500")

# channels
CH_INFO = 0x0015
CH_SETTINGS = 0x001E
CH_FILE = 0x8007


def checksum(data: bytes) -> int:
    return sum(data) & 0xFF


@dataclass
class Frame:
    flags: int
    msg_id: int
    src: bytes
    dst: bytes
    channel: int
    payload: bytes = b""

    def encode(self) -> bytes:
        key = struct.pack("<H", self.msg_id) + self.src + self.dst + struct.pack("<H", self.channel)
        if len(key) != 12:
            raise ValueError("routing key must be 12 bytes")
        body = bytes([START, self.flags]) + struct.pack("<H", len(self.payload)) + key + self.payload
        return body + bytes([checksum(body)])

    def __str__(self) -> str:
        return (
            f"flags={self.flags:02x} id={self.msg_id:04x} "
            f"chan={self.channel:04x} len={len(self.payload)} "
            f"payload={self.payload.hex() or '-'}"
        )


def decode(data: bytes) -> Frame:
    """Decode one frame; raises ValueError on anything malformed."""
    if len(data) < 17:
        raise ValueError(f"frame too short ({len(data)} bytes)")
    if data[0] != START:
        raise ValueError(f"bad start byte 0x{data[0]:02x}")
    flags = data[1]
    length = struct.unpack_from("<H", data, 2)[0]
    total = 16 + length
    if len(data) < total + 1:
        raise ValueError(f"truncated frame: need {total + 1}, have {len(data)}")
    if checksum(data[:total]) != data[total]:
        raise ValueError("checksum mismatch")
    key = data[4:16]
    return Frame(
        flags=flags,
        msg_id=struct.unpack_from("<H", key, 0)[0],
        src=key[2:6],
        dst=key[6:10],
        channel=struct.unpack_from("<H", key, 10)[0],
        payload=data[16:total],
    )


def split_stream(blob: bytes) -> list[bytes]:
    """Split a raw byte stream into frames (used when testing against captures)."""
    out, i = [], 0
    while (i := blob.find(bytes([START]), i)) != -1:
        if i + 17 > len(blob):
            break
        length = struct.unpack_from("<H", blob, i + 2)[0]
        end = i + 16 + length + 1
        if end > len(blob):
            break
        candidate = blob[i:end]
        try:
            decode(candidate)
        except ValueError:
            i += 1
            continue
        out.append(candidate)
        i = end
    return out


# --- TLV helpers -------------------------------------------------------------

def tlv_parse(payload: bytes) -> list[tuple[int, bytes]]:
    """Parse [attr_id u8][len u8][value...] records."""
    out, i = [], 0
    while i + 2 <= len(payload):
        attr, ln = payload[i], payload[i + 1]
        if i + 2 + ln > len(payload):
            break
        out.append((attr, payload[i + 2 : i + 2 + ln]))
        i += 2 + ln
    return out


def tlv_pack(attr: int, value: bytes) -> bytes:
    if not 0 <= attr <= 0xFF or len(value) > 0xFF:
        raise ValueError("attr or value too large")
    return bytes([attr, len(value)]) + value


def tlv_to_dict(payload: bytes) -> dict[int, bytes]:
    return dict(tlv_parse(payload))


ATTR_MIC_GAIN = 0x04        # 1 byte, dB  (verified: 0x12 = 18 dB, 0x18 = 24 dB)
