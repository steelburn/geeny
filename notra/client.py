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

    # --- record control -----------------------------------------------------
    #
    # Evidence (capture extrec2, vendor app 18:40-18:43):
    #   0x12 = 1  0x0b = 1        arm — device records from its own button without the app
    #   0x13 = 1a 0b 0b 02 <tick u16le>   record context; tick advances ~4 per second
    #   0x0b = 0                  release, so the vendor app can bind again
    #
    # Writing the context does NOT start a take on firmware v1.14 (three variants tried;
    # no file key appears afterwards). The device's own button remains the trigger - the
    # app arms it, then picks the take up with pull_latest().

    ATTR_RELEASE = 0x0B
    ATTR_ARM = 0x12
    ATTR_REC_CTX = 0x13
    ATTR_TRANSFER_MODE = 0x16
    CTX_HEADER = bytes.fromhex("1a0b0b02")

    @staticmethod
    def _ctx_payload(ticks: int) -> bytes:
        return NotraClient.CTX_HEADER + struct.pack("<H", ticks & 0xFFFF)

    async def arm(self) -> None:
        """Let the device record without the vendor app."""
        await self.set_attr(self.ATTR_ARM, b"\x01")
        await asyncio.sleep(0.15)
        await self.set_attr(self.ATTR_RELEASE, b"\x01")

    async def deactivate(self) -> None:
        """Release the device so the vendor app can bind to it again."""
        await self.set_attr(self.ATTR_RELEASE, b"\x00")
        await asyncio.sleep(0.2)
        await self.set_attr(self.ATTR_ARM, b"\x00")

    async def record_start(self, ticks: int | None = None) -> bool:
        """Arm, then write the record context.

        Returns True when a take is already waiting to be pulled. On this firmware the
        device usually ignores a remote start, so the caller should treat False as
        'press the record button' rather than as a hard failure.
        """
        await self.arm()
        await asyncio.sleep(0.3)
        self._ticks = ticks if ticks is not None else getattr(self, "_ticks", 0x2A20)
        await self.set_attr(self.ATTR_REC_CTX, self._ctx_payload(self._ticks))
        await asyncio.sleep(1.0)
        return (await self.file_key(timeout=4.0)) is not None

    async def record_stop(self, seconds: float = 0.0) -> None:
        """Write the closing record context (tick advanced by elapsed seconds)."""
        base = getattr(self, "_ticks", 0x2A20)
        self._ticks = base + int(seconds * 4)
        await self.set_attr(self.ATTR_REC_CTX, self._ctx_payload(self._ticks))

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
    #
    # File traffic is NOT raw bytes on the wire: it is a normal 0x55 frame
    # (flags 0x10 request / 0x11 response) on channel 0x8007 whose payload is
    #   aa | crc32(body) u32le | type | len u16le | body | crc16
    # Verified from capture extrec2, msg 0014-001a:
    #   host  86 02 00 e7 03            poll for the pending file
    #   dev   86 0c 00 <key u32> <u32> <u32>        (or 90 01 00 01 = none pending)
    #   host  81 04 00 <key>                        dev 81 18 00 <hash16><size u32><chunks u32>
    #   host  82 08 00 <key> <off u32>              dev 82 34 08 <seq><off><len><data>
    #   host  84 04 00 <key>                        close (device echoes it)

    @staticmethod
    def file_payload(body: bytes) -> bytes:
        """aa | crc32(body) | body | crc16 — the payload of a file-channel frame."""
        framed = bytes([0xAA]) + (zlib.crc32(body) & 0xFFFFFFFF).to_bytes(4, "little") + body
        return framed + crc16_bytes(framed)

    async def _file_send(self, body: bytes) -> int:
        return await self._send(F.FLAG_STATUS, CH_FILE, self.file_payload(body))

    @staticmethod
    def _file_parse(payload: bytes):
        """-> (type, body) or None if this is not a well-formed file payload."""
        if len(payload) < 10 or payload[0] != 0xAA:
            return None
        kind = payload[5]
        length = payload[6] | (payload[7] << 8)
        if length == 0 or len(payload) < 8 + length:
            return None
        return kind, payload[8 : 8 + length]

    async def file_key(self, timeout: float = 4.0, poll: bytes = bytes.fromhex("e703")) -> int | None:
        """Ask for the pending recording's key; None when the device has nothing to hand over."""
        await self._file_send(bytes([0x86, 0x02, 0x00]) + poll)
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            left = max(0.05, deadline - asyncio.get_event_loop().time())
            try:
                fr = await self._recv_frame(left)
            except asyncio.TimeoutError:
                break
            if fr.channel != CH_FILE or fr.flags != F.FLAG_DATA:
                continue
            parsed = self._file_parse(fr.payload)
            if parsed is None:
                continue
            kind, body = parsed
            if kind == 0x86 and len(body) >= 4:
                return struct.unpack_from("<I", body, 0)[0]
            # 90 01 00 01 = nothing pending; keep waiting until the deadline.
        return None

    async def open_latest(self) -> dict:
        key = await self.file_key()
        if key is None:
            raise RuntimeError("device reported no current file key (no new recording?)")
        await self._file_send(bytes([0x81, 0x04, 0x00]) + struct.pack("<I", key))
        meta = await self._recv_kind(0x81, timeout=5.0)
        info: dict = {"key": key}
        if meta and len(meta) >= 24:
            info["hash"] = meta[:16].hex()
            info["size"] = struct.unpack_from("<I", meta, 16)[0]
            info["chunks"] = struct.unpack_from("<I", meta, 20)[0]
        return info

    async def pull_latest(self, progress=None) -> bytes:
        info = await self.open_latest()
        return await self._pull(info, progress)

    async def pull_file(self, file_id: str, progress=None) -> bytes:
        """Select a file by its cloud id, then pull it."""
        await self.select_file(file_id)
        await asyncio.sleep(0.3)
        return await self.pull_latest(progress)

    async def _pull(self, info: dict, progress=None) -> bytes:
        """Request the stream once and read it to completion.

        Capture extrec2 msg 0014-0017 shows the real cadence:

            82 08 00 <key> <offset>     one request, host asks for the stream
            aa ... 82 34 08 ...         device streams every chunk back to back
            84 04 00 <key>              device: transfer complete
            85 04 00 <key>              host ack (device echoes it)

        Chunks are bucketed by offset because the device streams ahead of the
        reader; re-requesting per chunk makes it re-serve the tail.
        """
        key = info["key"]
        size = info.get("size") or 0
        data = bytearray()
        pending: dict[int, bytes] = {}
        await self._file_send(bytes([0x82, 0x08, 0x00]) + struct.pack("<II", key, 0))

        complete = False
        idle = 0
        while not complete:
            try:
                fr = await self._recv_frame(6.0)
            except asyncio.TimeoutError:
                idle += 1
                if size and len(data) >= size:
                    break
                if idle >= 3:
                    break
                continue
            if fr.channel != CH_FILE or fr.flags != F.FLAG_DATA:
                continue
            parsed = self._file_parse(fr.payload)
            if parsed is None:
                continue
            kind, body = parsed
            if kind == 0x82 and len(body) >= 10:
                _seq, off, dlen = struct.unpack_from("<IIH", body, 0)
                payload = body[10 : 10 + dlen]
                if off == len(data):
                    data += payload
                    while len(data) in pending:
                        data += pending.pop(len(data))
                elif off > len(data):
                    pending.setdefault(off, payload)
                if progress:
                    progress(len(data))
            elif kind == 0x84:
                complete = True

        await self._file_send(bytes([0x85, 0x04, 0x00]) + struct.pack("<I", key))
        if size and len(data) < size:
            raise RuntimeError(f"incomplete pull: {len(data)} of {size} bytes")
        return bytes(data[:size] if size else bytes(data))

    async def _recv_kind(self, kind: int, timeout: float = 5.0):
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            left = max(0.05, deadline - asyncio.get_event_loop().time())
            try:
                fr = await self._recv_frame(left)
            except asyncio.TimeoutError:
                break
            if fr.channel != CH_FILE or fr.flags != F.FLAG_DATA:
                continue
            parsed = self._file_parse(fr.payload)
            if parsed and parsed[0] == kind:
                return parsed[1]
        return None

    async def request_chunk_probe(self, key: int, offset: int, timeout: float = 8.0):
        await self._file_send(bytes([0x82, 0x08, 0x00]) + struct.pack("<II", key, offset))
        got = await self._recv_chunk(timeout)
        return got[2] if got else None

    async def _recv_chunk(self, timeout: float = 8.0):
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            left = max(0.05, deadline - asyncio.get_event_loop().time())
            try:
                fr = await self._recv_frame(left)
            except asyncio.TimeoutError:
                break
            if fr.channel != CH_FILE or fr.flags != F.FLAG_DATA:
                continue
            parsed = self._file_parse(fr.payload)
            if parsed is None or parsed[0] != 0x82:
                continue
            body = parsed[1]
            if len(body) < 10:
                continue
            seq, off, dlen = struct.unpack_from("<IIH", body, 0)
            return seq, off, body[10 : 10 + dlen]
        return None

    async def raw(self, hex_payload: str, channel: int = F.CH_SETTINGS,
                  flags: int = F.FLAG_STATUS) -> None:
        await self._send(flags, channel, bytes.fromhex(hex_payload))
