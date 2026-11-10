"""Read-only BLE probe for the Boya Notra Neo (no writes, no pairing prompts).

Run:  uv run --with bleak python research/probe_ble.py
Scans for the device, prints advertisement data, then dumps the GATT tree and
reads every readable characteristic. Nothing is written or modified.
"""
import asyncio
import sys

from bleak import BleakClient, BleakScanner

MATCH = ("notra", "boya", "neo")


async def main() -> None:
    print("scanning 12s ...")
    found = await BleakScanner.discover(timeout=12.0, return_adv=True)
    target = None
    for addr, (dev, adv) in found.items():
        name = adv.local_name or dev.name or ""
        rssi = adv.rssi
        print(f"\n{addr}  rssi={rssi}  name={name!r}")
        print(f"  service_uuids : {adv.service_uuids}")
        print(f"  service_data  : { {k: v.hex() for k, v in adv.service_data.items()} }")
        print(f"  mfr_data      : { {k: v.hex() for k, v in adv.manufacturer_data.items()} }")
        if any(m in name.lower() for m in MATCH):
            target = dev

    if target is None:
        print("\n!! no Boya/Notra advertisement seen (device may only advertise "
              "when unplugged or when the app is not holding the link)")
        return

    print(f"\n=== connecting to {target.address} ({target.name}) ===")
    async with BleakClient(target, timeout=25.0) as client:
        print(f"connected={client.is_connected}")
        for svc in client.services:
            print(f"\nSERVICE {svc.uuid}  {svc.description}")
            for ch in svc.characteristics:
                print(f"  CHAR {ch.uuid}  props={','.join(ch.properties)}  {ch.description}")
                for d in ch.descriptors:
                    print(f"    DESC {d.uuid}  {d.description}")
                if "read" in ch.properties:
                    try:
                        val = await client.read_gatt_char(ch)
                        print(f"    value: {val.hex()}  ({val!r})")
                    except Exception as exc:  # noqa: BLE001
                        print(f"    read failed: {exc}")
    print("\ndone (no data written)")


if __name__ == "__main__":
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(main())
