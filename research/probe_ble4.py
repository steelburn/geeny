"""Listen-only: subscribe to the notify characteristic and log everything for 30 s.

Also re-reads the read characteristic before/after subscribing. Writes nothing.

Run:  uv run --with bleak python research/probe_ble4.py
"""
import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner

SVC = "d8528400-66f0-40ff-8f3d-bc7a9853e04a"
CH_WRITE = "d8528401-66f0-40ff-8f3d-bc7a9853e04a"
CH_NOTIFY = "d8528402-66f0-40ff-8f3d-bc7a9853e04a"
CH_READ = "d8528403-66f0-40ff-8f3d-bc7a9853e04a"

TARGET = "notra"


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')}  {msg}", flush=True)


async def main() -> None:
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: TARGET in (ad.local_name or d.name or "").lower(), timeout=12.0
    )
    if dev is None:
        log("device not advertising")
        return

    async with BleakClient(dev, timeout=30.0) as client:
        log(f"connected to {dev.address}")
        for svc in client.services:
            log(f"service {svc.uuid}")
        try:
            log(f"read before subscribe: {bytes(await client.read_gatt_char(CH_READ)).hex()}")
        except Exception as exc:  # noqa: BLE001
            log(f"read failed: {exc}")

        def on_notify(_ch, data: bytearray) -> None:
            log(f"NOTIFY {len(data)}B  {bytes(data).hex()}  {bytes(data)!r}")

        await client.start_notify(CH_NOTIFY, on_notify)
        log("subscribed — listening 30 s (do not touch the device)")
        await asyncio.sleep(30)
        try:
            await client.stop_notify(CH_NOTIFY)
        except Exception:  # noqa: BLE001
            pass
        try:
            log(f"read after: {bytes(await client.read_gatt_char(CH_READ)).hex()}")
        except Exception as exc:  # noqa: BLE001
            log(f"read failed: {exc}")
        log("done (nothing written)")


if __name__ == "__main__":
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(main())
