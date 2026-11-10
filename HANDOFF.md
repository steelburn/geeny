# Handoff — Boya Notra Neo direct client

State of play, what is proven, what is left, and exactly how to run everything.
Last updated at the end of the session that cracked the CRC and the pull protocol.

---

## 1. What exists

| Path | What it is |
|---|---|
| `notra/` | Python client + CLI (bleak). Frame codec, CRC16, CRC32, attributes, file pull |
| `web/index.html` | Single-file Web Bluetooth console (Chrome/Edge). Connect, info, gain, pull |
| `research/PROTOCOL.md` | Full protocol write-up with evidence and disassembly offsets |
| `research/decode_btsnoop.py` | Android snoop → Boya frames |
| `research/extract_file.py` | Reassemble a recording out of a capture |
| `research/pdfs/manual.pdf` | FCC quick-start guide (the "USB drive mode" evidence) |
| `research/apk/` | Extracted APK (large — safe to delete; see §7) |
| `FEASIBILITY.md` | The original go/no-go assessment, updated with findings |
| `tools/platform-tools/` | adb (downloaded, not installed system-wide) |

## 2. Verified against hardware

- Connect: **no pairing, no bond, no auth.** Service `d8528400…`, write `…8401`, notify `…8402`.
- Frame codec: `0x55 | flags | len u16 | 12-byte routing key | payload | sum8`. 1794 frames decoded from captures.
- Heartbeat is mandatory (see §4) — without it, telemetry flows but commands are ignored.
- Read: name, serial, capabilities, status.
- Write: mic gain (`attr 0x04`), activation (`attr 0x12 = 1`, `attr 0x0b = 1` → device records without the vendor app).
- CRC16 tables recovered from `libcfdlink.so` (`0x1a825`/`0x1a925`); CRC32 for file frames is zlib.

## 3. The one open problem

Pull protocol is fully known:

```
settings  attr 0x13 = <6 bytes>      around a recording (start + stop writes)
settings  attr 0x16 = 2             transfer mode (0 closes)
0x8008    80 01 00 01            -> 80 04 <key u32>
0x8007    81 04 00 <key>         -> 81 18 <hash 16B> <size u32> <chunks u32>
0x8007    82 08 00 <key> <off>   -> chunk (2090 B), stream is Ogg Opus mono 16 kHz
0x8007    84 04 00 <key>         -> close
```

**Blocked on:** the key is only offered for a recording the device considers *pending/unsynced*.
Replaying the app's bytes later returns nothing, and `attr 0x16 = 2` alone does not reopen it.
The `attr 0x13` payload advances (`1a0b0b02 281d` → `…2a20`) like a counter/timestamp — that is
the most likely thing the pending-file state is keyed on.

### The experiment that closes it

Have the **vendor app record over BLE and pull immediately**, in one continuous session with
snooping on (no button, no gaps). That shows what `attr 0x13` carries and how the pending file
opens. ~2 minutes.

Then: `scripts/capture.sh`, `python research/decode_btsnoop.py <log>`, and compare the
`attr 0x13` writes with what we tried.

## 4. Things that cost time — don't rediscover them

- **Heartbeat framing.** Two separate sequences: frame `msg_id` = `0x0015, 0x0016, …` (+1) and the
  payload counter = `0xfc15, 0xfc2d, …` (+0x18). Mixing them up silently freezes commands while
  telemetry keeps flowing — it looks connected. `notra/client.py: heartbeat()` is correct.
- **msg ids are per-channel** (1, 2, 3 … on each channel), not global.
- **BLE is off while the device is on USB.** On USB it is a UAC1 sound card only, no storage.
- **Device sleeps.** If a scan finds nothing, the unit is off — press the power button briefly
  (white light), not long (long = record).
- **Windows bonding breaks the vendor app.** If you ever ran `BleakClient.pair()`, unpair before
  expecting the phone app to connect: `python - <<<` snippet in §6.
- **The tablet app can't connect unless the device was just woken.** Its Connect button silently
  does nothing otherwise.
- **Android snoop log is lossy for bulk data** (only ~23 % of a file body arrives) but complete
  for control frames. That's the logger, not the protocol.
- **`/data/misc/bluetooth/logs` is shell-denied** on a non-rooted device; `adb bugreport` **does**
  include `btsnoop_hci.log`. That's the only retrieval path.

## 5. Environment

```bash
uv --version                       # 0.12+ present, use `uv run --with ...`
tools/platform-tools/adb.exe       # adb, bundled
export MSYS_NO_PATHCONV=1          # REQUIRED before adb commands with device paths
```

Live BLE (device must be awake, and not held by the phone):

```bash
uv run --with bleak python -m notra scan
uv run --with bleak python -m notra info        # name / serial
uv run --with bleak python -m notra gain 20     # write mic gain
uv run --with bleak python -m notra --debug info   # <- note: --debug is global, before subcommand
```

Offline:

```bash
uv run python -m notra selftest <btsnoop>       # decode + validate every frame
uv run python -m notra frames   <btsnoop> --limit 20
uv run python tests/test_frame.py
```

Web app:

```bash
cd web && python -m http.server 8740            # open http://localhost:8740 in Chrome
```

## 6. Android / capture helpers

```bash
ADB=tools/platform-tools/adb.exe
$ADB devices                                     # authorize on the tablet first
$ADB shell cmd bluetooth_manager disable         # free the device from the phone
$ADB shell cmd bluetooth_manager enable

# snoop must be ON and applied at Bluetooth enable
$ADB shell settings put global bluetooth_hci_snoop_log 1
$ADB shell dumpsys bluetooth_manager | grep -i snoop     # want: sSnoopLogSettingAtEnable = FULL
```

Unpair from Windows (if the phone app refuses to connect):

```bash
uv run --with bleak python - <<'PY'
import asyncio
from winrt.windows.devices.bluetooth import BluetoothLEDevice
async def main():
    d = await BluetoothLEDevice.from_bluetooth_address_async(0x05A53DA9587B)  # 05:A5:3D:A9:58:7B
    if d: print(await d.device_information.pairing.unpair_async())
asyncio.run(main())
PY
```

## 7. Housekeeping

- `Boya+OS_1.2.50_APKPure.xapk` (159 MB) and `research/apk/` (345 MB) were only needed to extract
  `libcfdlink.so` and the command strings. Both CRC tables and the channel map are already
  embedded in `notra/crc.py` and the docs — delete freely.
  Keep `research/apk/arm64/lib/arm64-v8a/libcfdlink.so` if you want to re-derive anything.
- Device state at handoff: bound to Boya OS, firmware v1.14, SN `GL3410314055W`, tablet Bluetooth on.
- **The device's own memory was formatted** during this work (app "Remove"), so it holds only
  recordings made since. The vendor app's copies live in its cloud/account.

## 8. Suggested next moves (in order)

1. The §3 capture → finish `pull_latest()` end-to-end → wire it into `web/index.html` (the UI is
   already built: **Activate** and **Pull latest** buttons).
2. Add record control to the client (`attr 0x13` + `attr 0x16`), so the app can record, stop, pull
   and decode without touching the device.
3. Only then consider Flutter: the JS and Python protocol layers are mirrors, so
   `flutter_blue_plus` ports mechanically (connect → write → notify, same frames, same CRC).
