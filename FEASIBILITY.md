# Boya Notra Neo — can we build our own client instead of the Boya OS app?

**Short answer: yes for the part that matters (getting your recordings off the device), with a
caveat that decides the whole project.**

The device has **three** independent host interfaces, not one:

| Path | What it gives | Cost to build | Status |
|---|---|---|---|
| **USB mass storage** ("USB drive mode") | raw recording files, no app, no protocol RE | days | **highest chance, lowest effort — verify first** |
| **BLE (GATT)** | settings, status, on-phone file pull | days if protocol matches known platform, weeks if not | unknown until the GATT table is dumped |
| **Wi-Fi AP "Fast Transfer"** | fast bulk pull | weeks (undocumented) | optional |
| vendor cloud (`boyaos.com`) | transcription/summaries/templates | — | ToS-hostile, brittle, skip |

The one thing you *cannot* cheaply rebuild is the cloud AI layer (140+ language ASR, 60+ templates,
ChatGPT/Claude/Gemini/Grok summaries, cross-device sync). That is replaceable with Whisper +
an LLM on your own machine — but it is a different product, not a drop-in clone.

---

## 1. What the device actually is

- **Boya Notra Neo** — 63 × 63 × 8 mm AI note taker, MagSafe-magnetic, 2 MEMS mics + 1 VPU
  (bone conduction for calls), 8 GB local storage, 20 h recording, 5 m pickup, USB-C.
- **Radios** — FCC ID `2ARN3-50701NT` ("AI Recorder Card", Shenzhen Jiayz; covers the whole Notra
  family): **BLE 2402–2480 MHz** + **Wi-Fi 2412–2462 MHz (2.4 GHz only)**. Antenna supplied by
  Hesung Innovation (ZTX `DR-HEC005S`) → a Chinese ODM platform, not Boya silicon.
- **Companion app** — `com.wanmei.boyanotra` ("Boya OS", 深圳市完美声学科技有限公司).
- **Physical UI is self-sufficient**: a mode slider (ambient / phone-call / Bluetooth) and one
  button. Recording start/stop/highlight never needs the app. The app is needed for: device
  binding, noise reduction on/off, mic gain 0–30 dB, VCS gain low/med/high, Bluetooth-headset
  pairing, transfer, and the cloud features.

## 2. The finding that decides the project

The **official quick-start guide in the FCC filing** documents the LED states of the device,
and one of them is:

> `Solid Red` → **"USB drive mode"**

and for transfer:

> "Bluetooth is the default transfer method, or you can select **Fast Transfer**. When Fast
> Transfer is enabled, files will transfer via Wi-Fi. Once the transfer is complete, Wi-Fi turns
> off automatically, and the device reverts to Bluetooth connection mode."

A "USB drive mode" on a device with 8 GB of storage means the firmware can enumerate as **USB
Mass Storage**. If it does, the recordings appear as files in a filesystem on any PC or Android
phone — **no app, no BLE, no reverse engineering at all**. This is exactly how the closest
competitor behaves (PLAUD: "U-Disk mode … the device is mounted as USB mass storage").

That single test — plug it in, look at what mounts — collapses or expands the project.

## 3. Prior art: this class of device has been done before

Two independent, fully documented reverse-engineering projects exist for the PLAUD recorders
(same product category, same Chinese-ODM supply chain, same feature set):

- **`Kurikara-dev/plaud-note-nb100-re`** — complete BLE protocol: GATT service `0x1910`,
  notify `0x2BB0`, write `0x2BB1` (Tinnotech SDK), packet framing, full CMD map, handshake,
  file listing/transfer with resume, and raw-Opus→OGG reconstruction. Notable findings that
  transfer directly to this problem:
  - the device stores a **bind token**; a new client is normally rejected (`TOKEN_NOT_MATCH`)
    — but the **"depair" command (CMD 5) can be sent unauthenticated**, clearing the binding.
  - recordings are **bare Opus frames** (16 kHz, 20 ms, 80 B), needing an OGG container.
  - BLE throughput is **~20–25 KB/s** (a 40 MB file ≈ 15 min). Wi-Fi fast transfer exists for speed.
- **`roopen219/plaude-archiver`** — protocol v20 (RSA + ChaCha20-Poly1305) and v30 (ECDH P-256)
  variants, plus the Wi-Fi agent and the vendor cloud API. Its hard limit is the important one:
  > "for your own device, you need nothing from Plaud ever again. For a reset device you have no
  > signature for … assume it does verify and you cannot forge a signature."

**Translation for Boya:** if the Notra family sits on the same/nearby OEM stack (plausible — same
device genre, same BOM shape, same "bind before first use", same USB-drive-mode), then a
third-party client for *your own* unit is a solved-shape problem. If Boya's newer firmware uses
the encrypted protocol variant, you still win on your own bound device — but only after extracting
per-device keys from the phone (rooted) or from their cloud API.

## 4. What is genuinely unknown (needs the device in hand)

1. Does USB drive mode actually expose a readable filesystem, and in what format/encoding?
2. What GATT services/characteristics does it expose? Is `0x1910` (Tinnotech) among them?
3. Does it require binding before it will talk, and is there a depair/reset path?
4. Which protocol version does it report (plaintext vs. encrypted)?
5. What does the Wi-Fi "Fast Transfer" AP serve (HTTP file server? token?).

All five are answerable in well under an hour with the steps in §6.

## 5. Recommended shape of the app

**Phase 1 — "USB-first" archiver (low risk, real value).**
Desktop (Tauri or .NET) + Android:
- watch for the device mounting (USB MSC), copy new files, name them by timestamp
- transcribe locally (whisper.cpp) and summarise with a local/remote LLM
- your own storage/sync, no account, no cloud
- keeps 100 % of the audio quality, drops 0 % of the functionality that matters offline

**Phase 2 — BLE client (only if needed).**
Only worth it for: reading/setting mic gain, NR, VCS gain; status/battery; and pulling files
on a phone without a cable. Reuse the documented Tinnotech packet framing as a hypothesis and
fuzz it against the real device.

**Phase 3 — Wi-Fi fast transfer (nice to have).**
Only if bulk pull over BLE proves too slow and you need cable-free bulk transfer.

**Do not** build on Boya's cloud API. `boyaos.com` is a Shopify storefront with a small
`api.boyaos.com` contact/inquiry surface; the app backend is undocumented, authenticated, and
using it programmatically is a ToS problem with no stability guarantee.

## 6. Probe plan (do this before writing code)

With the Notra Neo and a PC:

```bash
# 1. USB mass storage — the decisive test
#   Windows: watch for a new drive letter / disk
powershell -c "Get-Disk; Get-Volume"        # before and after plugging in
#   Linux/macOS
lsusb -v 2>/dev/null | grep -iE "bInterfaceClass +8|Mass Storage"
dmesg | tail -20    # or: system_profiler SPUSBDataType
# If a volume mounts: copy everything off, then identify the container
file * ; xxd -l 64 <file>                   # Opus/Ogg? WAV? custom?
ffprobe <file>

# 2. BLE GATT table
#   phone: nRF Connect -> connect -> "Services" tab -> screenshot the whole tree
#   or desktop:
python -m pip install bleak
python - <<'PY'
import asyncio
from bleak import BleakScanner, BleakClient
async def main():
    for d in await BleakScanner.discover(timeout=8):
        print(d.address, d.name, d.metadata.get("uuids"))
    # then: BleakClient(<address>) -> for s in client.services: print(s)
asyncio.run(main())
PY
bluetoothctl connect <MAC>; bluetoothctl list-attributes   # alternative

# 3. Wi-Fi fast transfer
#   trigger "Fast Transfer" in the app, then join the device's AP and scan it:
curl -s http://192.168.4.1/ ; nmap -p- --min-rate 2000 192.168.4.1
```

Record results in `research/PROBE.md`. **Gate:** if (1) works → go straight to Phase 1 and stop
worrying about BLE. If (1) fails and (2) shows `0x1910`/`0x2BB0`/`0x2BB1` → Phase 2 is de-risked
and should take ~2–3 weeks. If (1) fails and (2) shows an unfamiliar encrypted stack → budget
6+ weeks or drop to "use the official app for sync, build only the post-processing pipeline".

## 7. Risks

- **Binding/ownership.** Modern recorders bind to an account token; a third-party client may need
  a depair command or a factory reset. Reset flows often erase the device.
- **Crypto on newer firmware.** RSA/ECDH handshakes require vendor-issued material. You can hold
  your *own* device's keys; you cannot impersonate the vendor for a factory-reset unit.
- **Firmware updates only via the app.** Skipping the app means missing fixes; flashing is out of
  scope and risky.
- **iOS.** USB MSC is not mountable; CoreBluetooth is possible but App Store review + the
  encrypted-handshake problem make iOS the worst first target. Start on Windows/macOS/Android.
- **Warranty and ToS.** Interoperability RE for your own device is generally accepted (e.g. DMCA
  §1201(f), EU Software Directive art. 6), but it voids support and Boya owes you nothing. Keep
  protocol notes original, publish no vendor code — the precedent repos do exactly that.
- **Quality ceiling.** Whatever you build reads the raw recordings; the vendor's AI polish
  (templates, diarisation, mind maps) is a separate, larger build.

## 8. Verdict

**Updated after hands-on probing + APK analysis — see `research/PROTOCOL.md`.**

The transport question is settled: the device accepts an **unauthenticated BLE connection** and
exposes a single custom service (`d8528400…`, write `…8401` / notify `…8402`). It does **not**
use the documented Tinnotech stack, so the published command map does not apply — but the frame
format was recovered from the vendor's own `libcfdlink.so` (A-AArch64, unstripped):

```
00        0x55                       start
01        flags | 0x10
02..03    payload length (u16 LE)
04..15    command / attribute key / seq
16..      payload
16+len    sum8 of all preceding bytes      total = len + 17
```

| Goal | Reality now | Effort |
|---|---|---|
| Connect to the device from a PC | **works** — no auth, no bond (`research/probe_ble3.py`) | done |
| Build/parse frames | **done** — header, routing key, checksum verified on 952 live frames | done |
| Read settings / battery / SN / firmware | **done** — TLV attributes captured live | done |
| Write settings (gain/NR/VCS) | **done** — mic gain 18↔24 dB exercised on hardware | done |
| Pull a recording | **protocol captured end-to-end** (chunks of 2090 B, Ogg Opus 16 kHz mono) | 1–2 weeks to harden |
| USB mass storage | **not reachable** — USB gives UAC1 audio only | n/a |
| Wi-Fi fast transfer | unexamined (`NativeSyncPlugin`, `WiFiConnectHelper`) | optional |
| Vendor cloud AI (transcripts, templates) | not worth cloning | — |

**Verdict: go.** The client is a transcription job, not a research project. What remains is
polish — per-attribute payload layouts for the handful of settings we care about, the file-list
response parsing, and retry/resume behaviour on a lossy link.

Recommended build order: (1) BLE client that lists files and pulls them as Ogg Opus,
(2) local whisper.cpp + LLM summarisation, (3) settings write (`mic gain`, `NR`, `VCS`),
(4) optional Wi-Fi fast path for large recordings.

---

### Evidence

- Quick-start guide (FCC exhibit, `2ARN3-50701NT`) — USB drive mode, BLE/Wi-Fi transfer, binding,
  headset pairing: `research/pdfs/manual.pdf`
- FCC filing (BLE 2402–2480, Wi-Fi 2412–2462, applicant, ODM antenna): fccid.io/2ARN350701NT
- Product page (cloud AI, 8 GB, transfer methods): boyaos.com/products/boya-notra-neo
- Hands-on review (app-side settings: NR, mic gain 0–30 dB, VCS gain): en.techreviewer.de
- App identity: play.google.com `com.wanmei.boyanotra`
- Prior art: `github.com/Kurikara-dev/plaud-note-nb100-re`,
  `github.com/roopen219/plaude-archiver` (protocol notes saved in `research/plaud_protocol.md`)
- No public Boya SDK, developer API or MCP surface found.
