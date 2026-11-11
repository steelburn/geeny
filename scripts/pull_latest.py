"""Pull the device's pending recording and save it as Ogg Opus (research tool).

    uv run --with bleak python scripts/pull_latest.py [out.ogg]

Exits non-zero when the device is holding no unsynced recording.
"""
from __future__ import annotations

import asyncio
import pathlib
import sys

sys.path.insert(0, ".")

from notra.client import NotraClient
from notra.transport import BleTransport


async def main() -> int:
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "latest.ogg")
    client = NotraClient(BleTransport(), debug=False)
    await client.connect()
    try:
        await client.heartbeat()
        info = await client.get_info()
        print(f"device : {info.name} / {info.serial}")

        key = await client.file_key()
        print(f"key    : {key if key is None else hex(key)}")
        if key is None:
            print("nothing pending — record on the device first")
            return 2

        meta = await client.open_latest()
        print(f"meta   : size={meta.get('size')} chunks={meta.get('chunks')} hash={meta.get('hash')}")

        def progress(n: int) -> None:
            print(f"  {n} bytes", end="\r", flush=True)

        data = await client._pull(meta, progress=progress)
        print(f"\npulled : {len(data)} bytes")
        print(f"magic  : {data[:4]!r}  (want b'OggS')")
        out.write_bytes(data)
        print(f"saved  : {out.resolve()}")
        return 0 if data[:4] == b"OggS" else 1
    finally:
        await client.close()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
