"""Notra client: session handling on top of a transport."""
from __future__ import annotations

import asyncio
import struct
import zlib
from dataclasses import dataclass, field

from . import frame as F
from .crc import crc16_bytes
from .transport import APP_NODE, DEV_NODE

# Heartbeat: msg_id and the in-payload counter are two separate sequences.
# First frame observed from the app was msg_id=0x0015 with counter=0xfc15, then
# msg_id=0x0016 with 0xfc2d, i.e. the counter advances by 0x18 per beat.
# Sending anything else silently freezes the command channel.
HB_PREFIX = bytes.fromhex("00600900020a")
HB_ID_START = 0x0015
HB_CTR_START = 0xFC15
HB_CTR_STEP = 0x18

CH_SN, CH_NAME, CH_CAPS, CH_STATUS = 0x0017, 0x0018, 0x0021, 0x0022
CH_FILE, CH_FILE_CTL = 0x8007, 0x8008
ATTR_MIC_GAIN = 0x04
ATTR_FILE_ID = 0x11
CHUNK = 2090


class FrameAssembler:
    """Turns a notification byte stream into whole frames.

    The device may send one frame per notification or split a large frame across
    several. Rather than model that, resync on 0x55 and accept a frame only when
    its length and checksum are valid.
    """

    def __init__(self) -> None:
        self.buf = bytearray()

    def feed(self, chunk: bytes) -> list[F.Frame]:
        self.buf += chunk
        out: list[F.Frame] = []
        while True:
            i = self.buf.find(b"\x55")
            if i < 0:
                self.buf.clear()
                return out
            if i:
                del self.buf[:i]
            if len(self.buf) < 17:
                return out
            total = 16 + int.from_bytes(self.buf[2:4], "little")
            if len(self.buf) < total + 1:
                return out
            try:
                fr = F.decode(bytes(self.buf[: total + 1]))
            except ValueError:
                del self.buf[0]
                continue
            out.append(fr)
            del self.buf[: total + 1]


@dataclass
class DeviceInfo:
    raw: dict[int, bytes] = field(default_factory=dict)
    name: str = ""
    serial: str = ""
    firmware: str = ""

    def __str__(self) -> str:
        rows = [f"name      : {self.name or '?'}",
                f"serial    : {self.serial or '?'}",
                f"firmware  : {self.firmware or '?'}"]
        for attr, val in sorted(self.raw.items()):
            rows.append(f"attr 0x{attr:02x} : {val.hex()}")
        return "\n".join(rows)


class NotraClient:
    def __init__(self, transport, debug: bool = False) -> None:
        self.t = transport
        self.debug = debug
        self._chan_seq: dict[int, int] = {}
        self._hb_id = HB_ID_START
        self._hb_ctr = HB_CTR_START
        self._asm = FrameAssembler()

    # --- plumbing -----------------------------------------------------------
    def _next_id(self, channel: int) -> int:
        """msg ids are per-channel sequence numbers (1, 2, 3 ... on each channel)."""
        nxt = (self._chan_seq.get(channel, 0) + 1) & 0xFFFF
        self._chan_seq[channel] = nxt
        return nxt

    async def _send(self, flags: int, channel: int, payload: bytes = b"",
                    dst: bytes = DEV_NODE) -> int:
        msg_id = self._next_id(channel)
        data = F.Frame(flags, msg_id, APP_NODE, dst, channel, payload).encode()
        if self.debug:
            print(f"  -> {data.hex()}")
        await self.t.send(data)
        return msg_id

    async def _recv_frame(self, timeout: float = 5.0) -> F.Frame:
        while True:
            ready = self._asm.feed(b"")
            if ready:
                return ready.pop(0)
            data = await self.t.recv(timeout)
            if self.debug:
                print(f"  <- {data.hex()}")
            self._asm.buf += data

    async def connect(self) -> None:
        await self.t.connect()

    async def close(self) -> None:
        await self.t.close()

    # --- operations ---------------------------------------------------------
    async def heartbeat(self) -> None:
        """Keep-alive; the device stops serving commands if this is malformed."""
        payload = (HB_PREFIX + self._hb_ctr.to_bytes(2, "little")
                   + (0).to_bytes(4, "little") + bytes([0x2C]))
        fr = F.Frame(F.FLAG_REQUEST, self._hb_id, APP_NODE, bytes(4), 0x0000, payload)
        if self.debug:
            print(f"  -> {fr.encode().hex()}")
        await self.t.send(fr.encode())
        self._hb_id = (self._hb_id + 1) & 0xFFFF
        self._hb_ctr = (self._hb_ctr + HB_CTR_STEP) & 0xFFFF

    async def get_info(self, timeout: float = 6.0) -> DeviceInfo:
        """CMD_GET_INFO: empty payload on channel 0x15; device answers with a TLV blob."""
        await self._send(F.FLAG_STATUS, F.CH_INFO, b"")
        info = DeviceInfo()
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            left = max(0.05, deadline - asyncio.get_event_loop().time())
            fr = await self._recv_frame(left)
            if fr.channel != F.CH_INFO or not fr.payload:
                continue
            info.raw.update(F.tlv_to_dict(fr.payload[:-2]))
            break
        info.name = (await self.read_attr(CH_NAME) or b"").decode("ascii", "replace").strip("\x00")
        info.serial = (await self.read_attr(CH_SN) or b"").decode("ascii", "replace").strip("\x00")
        return info

    async def set_mic_gain(self, db: int) -> None:
        if not 0 <= db <= 0xFF:
            raise ValueError("gain must be 0..255")
        await self.set_attr(ATTR_MIC_GAIN, bytes([db]))

    # --- attribute layer ----------------------------------------------------
    async def get_attr(self, channel: int, timeout: float = 3.0) -> bytes | None:
        """Generic getter: `00 00 00` on a channel, reply `00 <value> <crc16>`."""
        await self._send(F.FLAG_STATUS, channel, b"\x00\x00\x00")
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            left = max(0.05, deadline - asyncio.get_event_loop().time())
            fr = await self._recv_frame(left)
            if fr.channel == channel and fr.flags == F.FLAG_DATA:
                body = fr.payload[:-2] if len(fr.payload) >= 2 else b""
                return body[1:] if body[:1] == b"\x00" else body
        return None

    async def read_attr(self, channel: int) -> bytes | None:
        return await self.get_attr(channel)

    async def set_attr(self, attr: int, value: bytes) -> None:
        tlv = F.tlv_pack(attr, value)
        await self._send(F.FLAG_STATUS, F.CH_SETTINGS, tlv + crc16_bytes(tlv))

    async def read_info(self) -> dict[str, str]:
        out = {}
        for label, ch in (("name", CH_NAME), ("serial", CH_SN)):
            val = await self.get_attr(ch)
            if val:
                out[label] = val.decode("ascii", "replace").strip("\x00")
        return out

    # --- file transfer ------------------------------------------------------
    @staticmethod
    def _file_frame(body: bytes) -> bytes:
        """File-channel frame: aa | crc32(body) LE | body | crc16."""
        framed = bytes([0xAA]) + (zlib.crc32(body) & 0xFFFFFFFF).to_bytes(4, "little") + body
        return framed + crc16_bytes(framed)

    async def open_latest(self) -> dict:
        """Open whatever recording the device considers current (no id needed).

        Sequence captured from the vendor app:
          0x8008  80 01 00 01                 -> 80 04 <key u32>
          0x8007  81 04 00 <key>              -> 81 18 <16B hash> <size u32> <chunks u32>
        """
        key = await self.file_key()
        if key is None:
            raise RuntimeError("device reported no current file key (no new recording?)")
        body = bytes([0x81, 0x04, 0x00]) + struct.pack("<I", key)
        await self.t.send(self._file_frame(body))
        meta = await self._recv_type(0x81, timeout=5.0)
        info = {"key": key}
        if meta and len(meta) >= 24:
            info["hash"] = meta[:16].hex()
            info["size"] = struct.unpack_from("<I", meta, 16)[0]
            info["chunks"] = struct.unpack_from("<I", meta, 20)[0]
        return info

    async def pull_latest(self, progress=None) -> bytes:
        info = await self.open_latest()
        key = info["key"]
        expect = info.get("chunks") or 0
        data = bytearray()
        offset = 0
        while True:
            body = bytes([0x82, 0x08, 0x00]) + struct.pack("<II", key, offset)
            await self.t.send(self._file_frame(body))
            got = await self._recv_chunk()
            if got is None:
                raise RuntimeError(f"no chunk at offset {offset}")
            _seq, off, payload = got
            data += payload
            offset += len(payload)
            if progress:
                progress(offset)
            if len(payload) < CHUNK or (expect and offset >= info.get("size", 1 << 30)):
                break
        # close the transfer
        body = bytes([0x84, 0x04, 0x00]) + struct.pack("<I", key)
        await self.t.send(self._file_frame(body))
        return bytes(data)

    async def _recv_type(self, kind: int, timeout: float = 5.0):
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            left = max(0.05, deadline - asyncio.get_event_loop().time())
            fr = await self._recv_frame(left)
            if fr.channel != CH_FILE or fr.flags != F.FLAG_DATA:
                continue
            pay = fr.payload
            if len(pay) >= 20 and pay[0] == 0xAA and pay[5] == kind:
                return pay[6:len(pay) - 2]
        return None

    async def select_file(self, file_id: str) -> None:
        await self.set_attr(ATTR_FILE_ID, file_id.encode("ascii"))

    async def file_key(self, timeout: float = 4.0) -> int | None:
        await self._send(F.FLAG_STATUS, CH_FILE_CTL, bytes.fromhex("80010001"))
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            left = max(0.05, deadline - asyncio.get_event_loop().time())
            fr = await self._recv_frame(left)
            if fr.channel == CH_FILE_CTL and fr.flags == F.FLAG_DATA:
                body = fr.payload[:-2]
                if body[:2] == b"\x80\x04":
                    return struct.unpack_from("<I", body, 2)[0]
        return None

    async def pull_file(self, file_id: str, progress=None) -> bytes:
        """Select a file, then pull every chunk. Returns raw Ogg Opus bytes."""
        await self.select_file(file_id)
        await asyncio.sleep(0.3)
        key = await self.file_key()
        if key is None:
            raise RuntimeError("device did not report a file key")
        data = bytearray()
        offset = 0
        while True:
            body = bytes([0x82, 0x08, 0x00]) + struct.pack("<II", key, offset)
            await self.t.send(self._file_frame(body))
            got = await self._recv_chunk()
            if got is None:
                raise RuntimeError(f"no chunk at offset {offset}")
            _seq, off, payload = got
            if off != offset:
                raise RuntimeError(f"offset mismatch: asked {offset}, got {off}")
            data += payload
            offset += len(payload)
            if progress:
                progress(offset)
            if len(payload) < CHUNK:
                break
        return bytes(data)

    async def request_chunk_probe(self, key: int, offset: int, timeout: float = 8.0):
        body = bytes([0x82, 0x08, 0x00]) + struct.pack("<II", key, offset)
        await self.t.send(self._file_frame(body))
        got = await self._recv_chunk(timeout)
        return got[2] if got else None

    async def _recv_chunk(self, timeout: float = 8.0):
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            left = max(0.05, deadline - asyncio.get_event_loop().time())
            fr = await self._recv_frame(left)
            if fr.channel != CH_FILE or fr.flags != F.FLAG_DATA:
                continue
            pay = fr.payload
            if len(pay) < 20 or pay[0] != 0xAA:
                continue
            seq, off, dlen = struct.unpack_from("<IIH", pay, 8)
            return seq, off, pay[18:18 + dlen]
        return None

    async def raw(self, hex_payload: str, channel: int = F.CH_SETTINGS,
                  flags: int = F.FLAG_STATUS) -> None:
        await self._send(flags, channel, bytes.fromhex(hex_payload))
