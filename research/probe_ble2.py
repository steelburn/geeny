"""Find the Notra Neo even if it advertises without a name.

Scans, then for every nearby candidate (strong RSSI, no recognisable name) tries a
short read-only GATT connect and looks for a private/vendor service (0x1910-range
or any non-SIG UUID). Never writes to a device.

Run:  uv run --with bleak python research/probe_ble2.py
"""
import asyncio
import sys

from bleak import BleakClient, BleakScanner

STRONG_RSSI = -72          # only touch devices that are clearly in the room
SIG_PREFIXES = ("0000180", "0000181", "0000182", "0000180", "0000fe9", "0000fcf", "0000fef")


def is_sig(uuid: str) -> bool:
    u = uuid.lower().replace("-0000-1000-8000-00805f9b34fb", "")
    return any(u.startswith(p) for p in SIG_PREFIXES)


async def main() -> None:
    print("scanning 12s ...\n")
    found = await BleakScanner.discover(timeout=12.0, return_adv=True)

    ranked = sorted(found.items(), key=lambda kv: kv[1][1].rssi, reverse=True)
    cands = []
    for addr, (dev, adv) in ranked:
        name = adv.local_name or dev.name or ""
        interesting = (not name) or any(k in name.lower() for k in ("boya", "notra", "neo", "pen", "rec"))
        print(f"{addr}  rssi={adv.rssi:>4}  name={name!r}  svc={adv.service_uuids}")
        if adv.rssi >= STRONG_RSSI and interesting:
            cands.append((addr, dev, name))

    print(f"\n{len(cands)} candidate(s) to probe read-only\n")
    for addr, dev, name in cands:
        print(f"=== {addr} {name!r} ===")
        try:
            async with BleakClient(dev, timeout=12.0) as client:
                svcs = list(client.services)
                names = [s.uuid for s in svcs]
                print(f"  services: {names}")
                private = [s for s in svcs if not is_sig(s.uuid)]
                if private:
                    print("  ** NON-STANDARD SERVICES FOUND **")
                    for s in private:
                        print(f"  SERVICE {s.uuid} {s.description}")
                        for ch in s.characteristics:
                            print(f"    CHAR {ch.uuid} props={','.join(ch.properties)}")
                            if "read" in ch.properties:
                                try:
                                    v = await client.read_gatt_char(ch)
                                    print(f"      value: {v.hex()} ({v!r})")
                                except Exception as exc:  # noqa: BLE001
                                    print(f"      read failed: {exc}")
        except Exception as exc:  # noqa: BLE001
            print(f"  connect failed: {type(exc).__name__}: {exc}")
        print()


if __name__ == "__main__":
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(main())
