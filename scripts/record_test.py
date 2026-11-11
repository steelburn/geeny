"""Try to start/stop a recording over BLE and prove it by pulling the result.

    uv run --with bleak python scripts/record_test.py [seconds] [variant]

variants
    ctx   (default) arm 0x12=1 0x0b=1, record ctx 0x13 at start, again at stop
    pipe            arm 0x12=1 0x0b=1, stop with 0x0b=0
    ctx12           record ctx 0x13 at start, and 0x12=0 at stop

Evidence for the shape comes from capture extrec2 (vendor app, 18:40-18:43):
    18:40:27  attr 0x12 = 01        18:40:27  attr 0x0b = 01
    18:40:29  attr 0x13 = 1a0b0b02 281d
    18:42:32  attr 0x13 = 1a0b0b02 2a20
    18:42:59  attr 0x16 = 02   (transfer mode, then 00)
The trailing u16 advances ~4 units per second, so it is a 250 ms tick counter.
"""
from __future__ import annotations

import asyncio
import struct
import sys
import time

sys.path.insert(0, ".")

from notra.client import NotraClient
from notra.transport import BleTransport

ATTR_RELEASE = 0x0B
ATTR_ARM = 0x12
ATTR_REC_CTX = 0x13
CTX_HEADER = bytes.fromhex("1a0b0b02")


def ctx_payload(ticks: int) -> bytes:
    return CTX_HEADER + struct.pack("<H", ticks & 0xFFFF)


async def main() -> int:
    seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    variant = sys.argv[2] if len(sys.argv) > 2 else "ctx"
    client = NotraClient(BleTransport())
    await client.connect()
    try:
        await client.heartbeat()
        info = await client.get_info()
        print(f"device : {info.name} / {info.serial}  variant={variant}")

        ticks = 0x281D  # last value seen in the capture; only monotonicity seems to matter
        print("arm    : 0x12=1 0x0b=1")
        await client.set_attr(ATTR_ARM, b"\x01")
        await asyncio.sleep(0.2)
        await client.set_attr(ATTR_RELEASE, b"\x01")
        await asyncio.sleep(1.0)

        if variant in ("ctx", "ctx12"):
            print(f"start  : 0x13 = {ctx_payload(ticks).hex()}")
            await client.set_attr(ATTR_REC_CTX, ctx_payload(ticks))

        print(f"recording {seconds}s ...")
        await asyncio.sleep(seconds)
        ticks += seconds * 4

        if variant == "pipe":
            print("stop   : 0x0b=0")
            await client.set_attr(ATTR_RELEASE, b"\x00")
        else:
            print(f"stop   : 0x13 = {ctx_payload(ticks).hex()}")
            await client.set_attr(ATTR_REC_CTX, ctx_payload(ticks))
            if variant == "ctx12":
                await client.set_attr(ATTR_ARM, b"\x00")

        await asyncio.sleep(1.5)
        key = await client.file_key(timeout=6.0)
        print(f"key    : {key if key is None else hex(key)}")
        if key is None:
            print("RESULT : no key — nothing was recorded")
            return 2

        meta = await client.open_latest()
        data = await client._pull(meta)
        pages = data.count(b"OggS")
        last = 0
        i = 0
        while True:
            i = data.find(b"OggS", i)
            if i < 0 or i + 27 > len(data):
                break
            last = max(last, struct.unpack_from("<q", data, i + 6)[0])
            nseg = data[i + 26]
            i += 27 + nseg + sum(data[i + 27 : i + 27 + nseg])
        print(f"RESULT : {len(data)} bytes, {pages} pages, {last / 16000:.1f} s audio")
        print(f"saved  : {info.serial}-{int(time.time())}.ogg")
        open(f"{info.serial}-{int(time.time())}.ogg", "wb").write(data)
        return 0
    finally:
        await client.close()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
