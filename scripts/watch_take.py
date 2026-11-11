"""Watch for a pending take, then pull it.

    uv run --with bleak python scripts/watch_take.py [seconds]

Connects, arms the device, then polls for a file key every 3 s. The moment one
appears it pulls the take and prints its duration, so we can see whether a
recording becomes "pending" only under specific conditions.
"""
from __future__ import annotations

import asyncio
import struct
import sys
import time

sys.path.insert(0, ".")

from notra.client import NotraClient
from notra.transport import BleTransport


def ogg_duration(data: bytes) -> float:
    last, i = 0, 0
    while True:
        i = data.find(b"OggS", i)
        if i < 0 or i + 27 > len(data):
            return last / 16000
        last = max(last, struct.unpack_from("<q", data, i + 6)[0])
        nseg = data[i + 26]
        i += 27 + nseg + sum(data[i + 27 : i + 27 + nseg])


async def main() -> int:
    seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    client = NotraClient(BleTransport())
    await client.connect()
    try:
        await client.heartbeat()
        info = await client.get_info()
        print(f"device : {info.name} / {info.serial}", flush=True)
        await client.arm()
        print("armed  : press record on the device now", flush=True)

        deadline = time.time() + seconds
        while time.time() < deadline:
            key = await client.file_key(timeout=4.0)
            stamp = time.strftime("%H:%M:%S")
            if key is None:
                print(f"{stamp}  poll: nothing pending", flush=True)
                await asyncio.sleep(1.5)
                continue
            print(f"{stamp}  poll: KEY {hex(key)} — pulling", flush=True)
            meta = await client.open_latest()
            data = await client._pull(meta)
            out = f"{info.serial}-{int(time.time())}.ogg"
            open(out, "wb").write(data)
            print(f"RESULT bytes={len(data)} duration={ogg_duration(data):.1f}s -> {out}", flush=True)
            return 0
        print("RESULT nothing became pending in the window", flush=True)
        return 2
    finally:
        await client.close()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
