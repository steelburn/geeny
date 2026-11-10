"""Transports: live BLE (bleak) and offline replay from a btsnoop capture."""
from __future__ import annotations

import asyncio
import struct
from datetime import datetime, timedelta
from pathlib import Path

SERVICE = "d8528400-66f0-40ff-8f3d-bc7a9853e04a"
CHR_WRITE = "d8528401-66f0-40ff-8f3d-bc7a9853e04a"
CHR_NOTIFY = "d8528402-66f0-40ff-8f3d-bc7a9853e04a"
CHR_READ = "d8528403-66f0-40ff-8f3d-bc7a9853e04a"

DEVICE_NAME = "boya notra neo"


class BleTransport:
    """Live transport. Requires `bleak` (Windows/macOS/Linux)."""

    def __init__(self, address: str | None = None, debug: bool = False) -> None:
        self.address = address
        self.debug = debug
        self._client = None
        self._queue: asyncio.Queue[bytes] = asyncio.Queue()

    async def connect(self, timeout: float = 25.0) -> None:
        from bleak import BleakClient, BleakScanner

        dev = None
        if self.address:
            dev = await BleakScanner.find_device_by_address(self.address, timeout=timeout)
        else:
            dev = await BleakScanner.find_device_by_filter(
                lambda d, ad: (ad.local_name or d.name or "").lower() == DEVICE_NAME, timeout=timeout
            )
        if dev is None:
            raise RuntimeError("device not found — is it on and not connected to another host?")

        self._client = BleakClient(dev, timeout=timeout)
        await self._client.connect()
        await self._client.start_notify(CHR_NOTIFY, self._on_notify)

    def _on_notify(self, _ch, data: bytearray) -> None:
        self._queue.put_nowait(bytes(data))

    async def send(self, data: bytes) -> None:
        if self._client is None:
            raise RuntimeError("not connected")
        await self._client.write_gatt_char(CHR_WRITE, data, response=False)

    async def recv(self, timeout: float = 5.0) -> bytes:
        return await asyncio.wait_for(self._queue.get(), timeout)

    async def close(self) -> None:
        if self._client is not None:
            try:
                await self._client.stop_notify(CHR_NOTIFY)
            except Exception:  # noqa: BLE001
                pass
            await self._client.disconnect()
            self._client = None


class ReplayTransport:
    """Replays device->host frames from an Android btsnoop capture (no hardware needed)."""

    EPOCH_0AD = datetime(1, 1, 1)

    def __init__(self, path: str | Path, speed: float = 0.0) -> None:
        self.path = Path(path)
        self.speed = speed
        self._frames: list[tuple[datetime, bytes]] = []
        self._i = 0
        self.sent: list[bytes] = []

    def _records(self):
        raw = self.path.read_bytes()
        off, n = 16, len(raw)
        while off + 24 <= n:
            incl = struct.unpack(">I", raw[off + 4 : off + 8])[0]
            ts = struct.unpack(">Q", raw[off + 16 : off + 24])[0]
            yield self.EPOCH_0AD + timedelta(microseconds=ts), raw[off + 24 : off + 24 + incl]
            off += 24 + incl

    def load(self) -> None:
        """Join ACL fragments into L2CAP PDUs, then collect ATT notifications.

        Fragments of one PDU do not repeat the L2CAP header, so the header is read
        only when a PDU is started; every following fragment is appended verbatim.
        """
        pending: bytearray | None = None
        need = 0
        cid = 0
        for _when, data in self._records():
            if data[:1] != b"" or len(data) < 5:  # ACL data only
                continue
            acl = data[5:]
            if pending is None:
                if len(acl) < 4:
                    continue
                l2len, cid = struct.unpack_from("<HH", acl, 0)
                pending, need = bytearray(), l2len
                acl = acl[4:]
            pending += acl
            if len(pending) < need:
                continue
            pkt, pending = bytes(pending[:need]), None
            if cid == 0x0004 and pkt[:1] == b"" and len(pkt) > 3:
                self._frames.append((datetime.now(), pkt[3:]))

    async def connect(self, timeout: float = 25.0) -> None:
        from bleak import BleakClient, BleakScanner

        dev = None
        if self.address:
            dev = await BleakScanner.find_device_by_address(self.address, timeout=timeout)
        else:
            dev = await BleakScanner.find_device_by_filter(
                lambda d, ad: (ad.local_name or d.name or "").lower() == DEVICE_NAME, timeout=timeout
            )
        if dev is None:
            raise RuntimeError("device not found — is it on and not connected to another host?")

        self._client = BleakClient(dev, timeout=timeout)
        await self._client.connect()
        await self._client.start_notify(CHR_NOTIFY, self._on_notify)

    def _on_notify(self, _ch, data: bytearray) -> None:
        self._queue.put_nowait(bytes(data))

    async def send(self, data: bytes) -> None:
        if self._client is None:
            raise RuntimeError("not connected")
        await self._client.write_gatt_char(CHR_WRITE, data, response=False)

    async def recv(self, timeout: float = 5.0) -> bytes:
        return await asyncio.wait_for(self._queue.get(), timeout)

    async def close(self) -> None:
        if self._client is not None:
            try:
                await self._client.stop_notify(CHR_NOTIFY)
            except Exception:  # noqa: BLE001
                pass
            await self._client.disconnect()
            self._client = None


class ReplayTransport:
    """Replays device->host frames from an Android btsnoop capture (no hardware needed)."""

    EPOCH_0AD = datetime(1, 1, 1)

    def __init__(self, path: str | Path, speed: float = 0.0) -> None:
        self.path = Path(path)
        self.speed = speed
        self._frames: list[tuple[datetime, bytes]] = []
        self._i = 0
        self.sent: list[bytes] = []

    def _records(self):
        raw = self.path.read_bytes()
        off, n = 16, len(raw)
        while off + 24 <= n:
            incl = struct.unpack(">I", raw[off + 4 : off + 8])[0]
            ts = struct.unpack(">Q", raw[off + 16 : off + 24])[0]
            yield self.EPOCH_0AD + timedelta(microseconds=ts), raw[off + 24 : off + 24 + incl]
            off += 24 + incl

    def load(self) -> None:
        # Accumulate ACL fragments per connection handle, then slice out L2CAP PDUs.
        # This is the exact approach that validated 952/952 live frames (decode_btsnoop.py):
        # a single ATT notification of ~2 KB arrives as several ACL fragments, and each
        # fragment is not itself an L2CAP PDU.
        pending: dict[int, bytearray] = {}
        for _when, data in self._records():
            if data[:1] != b"" or len(data) < 5:  # only ACL data
                continue
            handle = struct.unpack_from("<H", data, 1)[0] & 0x0FFF
            acl = data[5:]
            if len(acl) < 4:
                continue
            l2len, cid = struct.unpack_from("<HH", acl, 0)
            frag = acl[4 : 4 + l2len]
            buf = pending.setdefault(handle, bytearray())
            buf += frag
            if len(buf) < l2len:
                continue
            pkt, pending[handle] = bytes(buf[:l2len]), bytearray()
            if cid == 0x0004 and pkt[:1] == b"" and len(pkt) > 3:
                self._frames.append((datetime.now(), pkt[3:]))

    async def connect(self, timeout: float = 25.0) -> None:
        if not self._frames:
            self.load()

    def iter_sync(self):
        """Yield every captured ATT notification without touching the event loop."""
        if not self._frames:
            self.load()
        for _when, data in self._frames:
            yield data

    async def send(self, data: bytes) -> None:
        self.sent.append(data)

    async def recv(self, timeout: float = 5.0) -> bytes:
        if self._i >= len(self._frames):
            raise asyncio.TimeoutError("replay exhausted")
        frame = self._frames[self._i][1]
        self._i += 1
        if self.speed:
            await asyncio.sleep(self.speed)
        return frame

    async def close(self) -> None:
        return None

    @property
    def remaining(self) -> int:
        return len(self._frames) - self._i


# routing nodes (re-exported for convenience)
APP_NODE = bytes.fromhex("01011d00")
DEV_NODE = bytes.fromhex("01022500")
