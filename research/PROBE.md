# Probe log — Boya Notra Neo (fill this in with the device in hand)

Date: ____  Unit: Notra Neo, colour ____, firmware (from app, if known): ____

## 1. USB mass storage — the decisive test  → **RESULT: NO STORAGE**

Run 2026-11-11, Windows 11, direct root-hub port.

- [x] Plugged into: **Windows 11 PC** (Intel USB 3.20 root hub)
- [x] A volume/drive appeared? **NO** — `Get-Volume` shows only C:, D: and a 0.9 GB
      recovery partition; `Get-Disk` shows only the two internal NVMe disks.
- [x] **What it does enumerate as:** `USB\VID_2F05&PID_4740` — BusReportedDeviceDesc
      **"Boya Notra Neo"**, one function only:
      `USB\VID_2F05&PID_4740&MI_00` → class **MEDIA**, service **usbaudio**,
      CompatibleIds `USB\Class_01&SubClass_02&Prot_00` = **USB Audio Class 1.0**.
      Creates two endpoints: `Microphone (Boya Notra Neo)` + `Speakers (Boya Notra Neo)`.
- [x] No HID, no vendor-specific interface, no CDC/serial, no WPD/MTP, no MSC.
      → **no vendor command channel over USB**, so the mode cannot be switched from the PC side.
- [x] Firmware revision reported by descriptor: `REV_0100`.
- [x] Historical device list: **no other PID/mode has ever enumerated** for VID 2F05.
- [x] No Boya/Notra BLE advertisement while plugged in (12 s scan, bleak).
- [x] No Boya Wi-Fi SSID broadcasting (`netsh wlan show networks`).

**Interpretation:** on USB the device is a plain UAC1 headset/mic. `USB drive mode`
(the LED state in the manual) is a *separate* device state that must be entered —
most likely from the app over BLE (the PLAUD equivalent, "U-Disk mode", is a device
setting sent over BLE), or by a button combination.

### Follow-up tests (same session)

| Attempt | Result |
|---|---|
| triple-click Record while on USB | no MSC; later observed **solid red = recording**, so red is *not* drive mode |
| long-press Record while on USB | same — and the device **dropped off the USB bus** while recording (no audio function either) |
| stop recording, replug cable | back to UAC1 audio: `Microphone` + `Speakers (Boya Notra Neo)`; **still no volume** |
| 24 s poll for a mass-storage attach | nothing ever appeared (`disks=2`, `removable=[]` throughout) |

**Conclusion so far:** no button combination reachable from the PC puts it into
mass-storage mode. USB gives live audio only. Storage access therefore depends on
the BLE/Wi-Fi path (app-initiated) — next test.

Original checklist kept for the next attempt:

- [ ] Filesystem: FAT32 / exFAT / other ____
- [ ] Directory layout:

```
(paste `ls -R` or `dir /s` output)
```

- [ ] File container: Opus raw / Ogg Opus / WAV / MP3 / custom ____
- [ ] `ffprobe` on one file:

```
(paste output)
```

- [ ] Files readable without ever installing/binding the Boya OS app? yes / no
- [ ] Device still records while mounted? yes / no

**Verdict:** if a volume appears and the audio decodes → go straight to Phase 1 (USB-first app).

## 2. BLE GATT table  → **CAPTURED (custom protocol, no auth needed to connect)**

- [x] First attempt (device on USB): 12 s scan — **no advertisement**. BLE is off in USB-audio mode.
- [x] Second attempt (unplugged, powered off): no advertisement.
- [x] Third attempt (factory reset → pairing mode): **advertises as `Boya Notra Neo`**,
      random static address `05:A5:3D:A9:58:7B`, RSSI −69.
- [x] Connect: **works with no pairing/bonding and no authentication** (a plain central connect).

### GATT tree (complete — one service only)

```
SERVICE d8528400-66f0-40ff-8f3d-bc7a9853e04a   (private, 128-bit)
  CHAR d8528401-…  write, write-without-response   app -> device
  CHAR d8528402-…  notify                          device -> app
  CHAR d8528403-…  read                            currently returns 0 bytes
```

No battery service, no device-information service, no standard GAP/GATT extras,
no second interface. This is a bare command channel — the simplest possible shape
for a third-party client.

### Behaviour observed

- Unprompted notifications: **none** in 30 s of subscription (device is silent until spoken to).
- The `…8403` read characteristic returns an **empty** value (before and while subscribed).
- Connection is **dropped after ~30 s idle** (or the pairing window closed) — the client
  must poll or keep the link busy.
- UUID is **not published anywhere** (DuckDuckGo: zero hits for the service or the
  characteristic UUIDs) → bespoke stack, not Tinnotech (`0x1910`) and not the
  `0x1911` family seen on a nearby device.

### What this means

Transport is solved: connect -> write frames to `...8401` -> read frames from `...8402`.
The frame format was then recovered from `libcfdlink.so` - see `research/PROTOCOL.md`.
Two ways to get it:

1. **APK analysis — DONE.** `libcfdlink.so` is unstripped; the frame format, checksum and
   command vocabulary are recovered in **`research/PROTOCOL.md`**.
2. **Android HCI snoop log — still the best confirmation** of the per-command payloads:
   *Developer options -> Enable Bluetooth HCI snoop log*, run one normal app session
   (bind, list recordings, change a setting, transfer a file), then pull
   `btsnoop_hci.log`. The frames decode mechanically now (0x55, len at 2..3, sum at end).

Black-box probing (guessing frames) is a distant third: every guess risks changing
device state (start recording, delete files), so it should only be used to confirm
findings, not to discover them.

- [x] Frame format: `0x55 | flags|0x10 | len u16le | 12B cmd/attr/seq | payload | sum8` (total = len+17)
- [x] Tool: bleak (Windows) — works, no bond needed
- [x] Advertised name: `Boya Notra Neo`  MAC: random static (e.g. `05:A5:3D:A9:58:7B`)
- [ ] Attribute paths / payload semantics (needs snoop log)
- [ ] Service UUIDs in advertisement: ____

```
(paste full service + characteristic dump)
```

- [ ] `0x1910` / `0x2BB0` / `0x2BB1` present? (Tinnotech signature) yes / no
- [ ] Connect without binding possible? yes / no
- [ ] Any readable "bind"/"token" characteristic? ____
- [ ] Protocol version byte, if reachable: ____

## 3. Wi-Fi fast transfer

- [ ] Triggered via app ("Fast Transfer") — device SSID: ____
- [ ] Client IP after joining: ____ / gateway: ____
- [ ] `nmap` result:

```
(paste)
```

- [ ] HTTP endpoints found: ____
- [ ] Any auth token required? ____

## 4. Notes / surprises

(anything else: LED behaviour, button sequences, reset procedure, serial number format)
