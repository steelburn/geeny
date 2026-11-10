"""Targeted connect to the Notra Neo with retries and a long timeout.

Read-only: connects, discovers services, reads readable characteristics. Never writes.

Run:  uv run --with bleak python research/probe_ble3.py
"""
import asyncio
import sys

from bleak import BleakClient, BleakScanner

TARGET_NAME = "boya notra neo"


async def connect_once(dev, attempt: int):
    print(f"\n--- attempt {attempt}: {dev.address} {dev.name!r}")
    try:
        client = BleakClient(dev, timeout=35.0, winrt={"use_cached_services": False})
        await client.connect()
        print(f"connected={client.is_connected}")
        svcs = list(client.services)
        if not svcs:
            print("  (no services discovered yet, retrying discovery)")
            svcs = list(await client.get_services())
        for s in svcs:
            print(f"SERVICE {s.uuid}  {s.description}")
            for ch in s.characteristics:
                print(f"  CHAR {ch.uuid} props={','.join(ch.properties)}")
                if "read" in ch.properties:
                    try:
                        v = await client.read_gatt_char(ch)
                        print(f"    value: {v.hex()}  ({v!r})")
                    except Exception as exc:  # noqa: BLE001
                        print(f"    read failed: {exc}")
        await client.disconnect()
        print("disconnected cleanly")
        return True
    except Exception as exc:  # noqa: BLE001
        print(f"  fail: {type(exc).__name__}: {exc}")
        return False


async def main() -> None:
    for attempt in range(1, 5):
        print(f"[{attempt}] scanning ...")
        dev = await BleakScanner.find_device_by_filter(
            lambda d, ad: (ad.local_name or d.name or "").lower() == TARGET_NAME
            or "notra" in (ad.local_name or d.name or "").lower(),
            timeout=12.0,
        )
        if dev is None:
            print("  not advertising at the moment (pairing window may have closed)")
        else:
            print(f"  found {dev.address} rssi={getattr(dev, 'rssi', None)}")
            if await connect_once(dev, attempt):
                return
        await asyncio.sleep(4)
    print("\nall attempts failed")


if __name__ == "__main__":
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(main())
