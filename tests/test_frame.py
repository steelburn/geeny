"""Offline regression tests: known-good frames from the live capture must decode."""
import sys, pathlib; sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import sys
from notra import frame as F

CASES = [
    # (hex, expected flags, channel, payload starts with)
    ("55100000010001011d00010225001500c2", 0x10, 0x0015, b""),
    ("55120d00150001011d0000000000000000600900020a15fc000000002c5a", 0x12, 0x0000, b"\x00\x60\x09"),
    ("55120d00d30c0102250001011d00000000980800020ae4923300bc0224d1", 0x12, 0x0000, b"\x00\x98\x08"),
    ("5511180004000102250001011d000100000f426f7961204e6f747261204e656f0040c001a0f14a25cb", 0x11, 0x0001, b"\x00\x0fBoya Notra Neo"),
    ("55100500020001011d00010225001e0012010160559a", 0x10, 0x001E, b"\x12\x01\x01"),
]

def main() -> int:
    fails = 0
    for hexs, flags, chan, prefix in CASES:
        try:
            fr = F.decode(bytes.fromhex(hexs))
        except ValueError as exc:
            print(f"FAIL decode {hexs[:24]}…: {exc}"); fails += 1; continue
        problems = []
        if fr.flags != flags: problems.append(f"flags {fr.flags:02x} != {flags:02x}")
        if fr.channel != chan: problems.append(f"chan {fr.channel:04x} != {chan:04x}")
        if not fr.payload.startswith(prefix): problems.append("payload prefix mismatch")
        if F.decode(fr.encode()).payload != fr.payload: problems.append("round-trip mismatch")
        print(("ok   " if not problems else "FAIL ") + f"{hexs[:20]}… " + "; ".join(problems))
        fails += bool(problems)

    # checksum must reject a corrupted frame
    bad = bytearray(bytes.fromhex(CASES[0][0])); bad[5] ^= 0xFF
    try:
        F.decode(bytes(bad)); print("FAIL corrupted frame accepted"); fails += 1
    except ValueError:
        print("ok   corrupted frame rejected")

    # TLV
    blob = bytes.fromhex("010153040118050101060100150c00207500001875 000000".replace(" ", ""))
    parsed = F.tlv_parse(blob)
    assert parsed[0] == (0x01, b"\x53"), parsed
    assert F.tlv_pack(0x04, b"\x18") == bytes.fromhex("040118")
    print(f"ok   TLV {len(parsed)} records; round-trip attr pack")

    print("\nall good" if not fails else f"\n{fails} failure(s)")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
