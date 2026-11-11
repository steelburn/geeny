# Boya Notra Neo — BLE protocol notes (from the official APK)

Everything below is derived from the vendor's own artefacts, in this order:

1. `Boya+OS_1.2.50_APKPure.xapk` → `com.wanmei.boyanotra.apk` (base) + `config.arm64_v8a.apk`
2. Live GATT enumeration against the physical unit (`research/probe_ble3.py`)
3. `libcfdlink.so` (AArch64, **not stripped**, 434 KB) — the device SDK
4. `classes3.dex` — the Java/Kotlin wrapper and command vocabulary

Stack: the app UI is **Flutter** (`libapp.so`); the device protocol lives in
**`libcfdlink.so`** ("CFDLink"), reached via `com.jiayz.device.CFDLinkNativeJni`.
The SDK is shared across Boya products (`BoyaMic`, `BoyaLink3`, `Notra`, `Memo`, `Magic`…),
so this protocol is the family protocol, not a Notra-Neo one-off.

---

## 1. GATT (verified against the device)

Device advertises as `Boya Notra Neo` on a random static address (e.g. `05:A5:3D:A9:58:7B`).
**No pairing, no bond, and no authentication is required to connect** — a plain central
connect was accepted on the first attempt from Windows/bleak.

```
SERVICE d8528400-66f0-40ff-8f3d-bc7a9853e04a
  d8528401-…   write, write-without-response    app  -> device
  d8528402-…   notify                           device -> app
  d8528403-…   read                             returns 0 bytes
```

- It is the **only** service exposed: no battery, no device-information, nothing standard.
- Silent until spoken to: 30 s of notification subscription produced zero frames.
- The link is dropped after ~30 s of idling.
- These UUIDs have no public hit anywhere → bespoke, not Tinnotech (`0x1910`) and not
  the `0x1911` family seen on an unrelated nearby device.

BLE is **off while the unit is on USB** — on USB it enumerates only as a USB Audio Class 1.0
device (`USB\VID_2F05&PID_4740&MI_00`, `usbaudio`, mic + speaker). No mass storage in any
state found so far (see `PROBE.md`).

---

## 2. Frame format — `cfdl_io_msg_sen` @ `0x3343c`

Disassembly (AArch64) reduced to the layout it builds:

```
byte 0        0x55                     start of frame
byte 1        msg[1] | 0x10            flags/type, ORed with 0x10 before transmit
byte 2..3     payload length, u16 LE   msg[2..3]  (CRC variant stores length+2)
byte 4..15    msg[4..15]               copied verbatim — command / attr / seq / reserved
byte 16..     payload                  memcpy(dst+16, msg->payload, len)
byte 16+len   8-bit additive checksum  (u8)(sum of every byte 0 .. 16+len-1)
```

- **Total frame length = payloadLen + 17**
- The checksum is a **plain byte-wise sum, mod 256** (`addv b0` over the buffer, plus a
  byte tail loop — no polynomial, no table).
- Port/context limit: device id > 3 → error `0x130`. Per-port state block is
  `0x30` bytes at `0x4e8000 + 0xe80 + id*0x30`.
- Zero-length payload is legal (allowed through; only requires the payload pointer to be
  non-null when len > 0). Max payload is checked against `0x961` (2401).

### CRC variant — `cfdl_io_msg_crc_sen` @ `0x33620` + `cfdl_io_create_payload_crc` @ `0x338c4`

A second sender exists for transports that want integrity:

- payload buffer is `len+2`; after the data comes a **CRC16**, computed byte-wise with
  two 256-entry tables (`0x1a825` = low byte, `0x1a925` = high byte),
  stored as `payload[len]`, `payload[len+1]`;
- header length becomes `len+2`;
- the same `0x55`/flags/16-byte header and trailing 8-bit sum apply.

The library also exports a pile of named CRC16 variants — `crc16_ccitt`, `_ccitt_false`,
`_xmodem`, `_x25`, `_modbus`, `_ibm`, `_maxim`, `_usb`, `_dnp` — so the exact table used for
a given device is a per-family detail. The BLE path (what the Notra Neo uses) is the
**simple-sum** sender.

---

## 3. Command vocabulary (from `classes3.dex`)

Present as constants in the Java layer:

```
CMD_GET_INFO      CMD_NOTIFY_STATUS    CMD_RST        CMD_OTA_INFO
CMD_GET_INFO_TLV  CMD_SEND_DATA        CMD_RST_FULL   CMD_OTA_IDENTIFICATION
CMD_SYNC
```

`CMD_GET_INFO_TLV` is qualified by:

```
CMD_GET_INFO_TYPE_CAPABILITIES   CMD_GET_INFO_TYPE_CHANNEL   CMD_GET_INFO_TYPE_STATUS
CMD_GET_INFO_TYPE_UPDATE         CMD_GET_INFO_TYPE_VERSION
```

So the handshake is: connect → write `CMD_GET_INFO`/`TLV` → receive a TLV blob describing
capabilities, channels, status, firmware/update and version.

## 4. Attribute layer ("sattribute")

The SDK is not a flat command list — it is a **typed attribute tree**, addressed by path:

| Symbol | Meaning |
|---|---|
| `cfdl_att_pack` @ `0x2b0ac` | parses an attribute path string into a packed key buffer |
| `create_device_attrs_packet(a, b, type)` @ `0x3f01c` | builds the 24-bit key `(type<<16) \| (a<<8) \| b` |
| `cfdl_att_get_value` / `_set_value` / `_get_number` / `_getString` / `_getJSON` | value accessors |
| `cfdl_att_subscribe`, `cfdl_att_subscribe_change`, `cfdl_sattribute_*` | subscriptions to attribute changes |
| `cfdl_att_get_path_from_name`, `cfdl_att_get_language_entry` | name ↔ path resolution |

Payloads for read/write of an attribute are therefore *path + typed value*, not raw
command IDs. Reproducing this by hand requires knowing the attribute paths for the
Notra Neo (mic gain, noise reduction, VCS gain, storage, file list…), which is the last
unknown.

## 5. File transfer

Symbols show the mechanism is **chunked, request/response**:

```
cfdl_file_init / _start / _run / _stop / _get_state
cfdl_filelist            cfdl_file_filelist_cb
cfdl_file_get_size       get_file_length
slice_file               get_file_slice_size
response_slice_file_request ,  Java_..._sendRequestSliceFileRequestToMcu
Java_..._pushFileToDevice_n      (device <- host)
cfdl_file_bootload       (firmware OTA path)
```

i.e. the host asks for slices of a file and the device streams them back — the same
shape as the documented PLAUD flow (list → request offsets → resume), which is a good
prior for how resume/offset fields behave.

Also visible: `OpusUtils_encodeOpus/decodeOpus` (`libopus.so` is bundled), and
`addFileTitleInFileByDevId` — the app **rewrites titles into the audio files** after
transfer, so the on-device recordings are containers it can edit.

---

## 6. What is left to discover

| Item | How |
|---|---|
| exact bytes 4..15 semantics (cmd vs attr key vs seq) | HCI snoop of one app session, or further RE of `cfdl_att_pack` |
| attribute paths/IDs for Notra Neo settings | same |
| file-list request/response payloads | same |
| Wi-Fi "Fast Transfer" channel | `NativeSyncPlugin` / `WiFiConnectHelper` (Java side, not yet decoded) |

**Recommended next step:** one Android session with *Developer options → Enable Bluetooth
HCI snoop log*, then pull `btsnoop_hci.log`. With §2 already known, the frames in that log
decode by inspection (start 0x55, len at 2..3, sum at end), which turns the remaining
table into data rather than research.

## 7. Reproduce

```bash
uv run --with androguard python research/apk/scan_refs.py classes3.dex CMD_SYNC 3
uv run --with androguard python research/apk/dump_pkg.py classes3.dex CFDLinkNativeJni
uv run --with pyelftools --with capstone python research/apk/disas.py cfdl_io_msg_sen
uv run --with pyelftools --with capstone python research/apk/disas.py cfdl_io_create_payload_crc
```

---

## 8. Live capture — verified against hardware (2026-11-11, 01:47–01:59)

Method: Lenovo TB336FU (Android 16), Boya OS `com.wanmei.boyanotra`, developer snoop log,
retrieved with `adb bugreport` (the only way on a non-rooted device — `/data/misc/bluetooth/logs`
is shell-denied). Decoder: `research/decode_btsnoop.py`, file extractor: `research/extract_file.py`.

### GATT handles in use

| UUID | ATT value handle |
|---|---|
| `d8528401-…` (write) | **0x0003** |
| `d8528402-…` (notify) | **0x0005** |

Connection is unauthenticated; peer was `xx:xx:xx:xx:58:7b`, one link, MTU ≈ 500.

### Frame header — confirmed

Every captured frame validated against §2 (`CHECKSUM OK`, 952 frames). The flags byte
(decimal values observed after the `| 0x10`):

| value | meaning |
|---|---|
| `0x10` | status / ack |
| `0x11` | data response (device → app) |
| `0x12` | request (app → device) |

The 12-byte key is a **routing tuple**, not opaque:

```
[key] = [msgId u16LE] [src 4B] [dst 4B] [channel u16LE]

app  node = 01 01 1d 00
dev  node = 01 02 25 00
channel   = 00 00  (attribute/control)   07 80  (file data)
```

The device swaps src/dst in its replies — e.g. app request
`1700 | 01011d00 | 01022500 | 0780` is answered as `1900 | 01022500 | 01011d00 | 0780`.

### Payloads are TLV

`[attr_id u8][len u8][value…]`, repeated. Two verified examples:

```
status blob (81 B):
  01 01 53 | 04 01 18 | 05 01 01 | 06 01 00 | 07 01 00 | 08 01 00 | 09 01 00
  0b 01 01 | 0d 02 01 0e | 15 0c <00 20 75 00> <00 18 75 00> 00 00
                                        ^ total KB  ^ free KB   (attr 0x15)

device name:   00 0f "Boya Notra Neo" 00 40 c0 01 a0 f1 4a
file request:  11 22 "cf26b00609951044bd8ea93e8268ea0dbe"     (attr 0x11 = file id, 34-char ASCII)
```

### File transfer — corrected model

Container is **Ogg Opus, mono, 16 kHz**. Work unit is a **chunk of 2090 bytes**.

File traffic is **not raw bytes**: every message is a normal `0x55` frame with
`flags = 0x10` (host request) / `0x11` (device response) on **channel `0x8007`**,
whose payload is:

```
aa | crc32(body) u32le | type | len u16le | body | crc16
```

`len` counts the body only. Types (host → device unless marked):

```
86 02 00 e7 03            poll for the pending take (sent every ~3 s while idle)
86 0c 00 <key u32> <u32> <u32>          device: current file key (0x86 response)
90 01 00 01                             device: nothing pending
81 04 00 <key u32>        open the take
81 18 00 <hash 16B> <size u32> <chunks u32>   device: file metadata
82 08 00 <key u32> <offset u32>         request the stream from this offset
82 34 08 <seq u32> <offset u32> <len u16> <data>   device: one chunk
84 04 00 <key u32>                      device: transfer complete
85 04 00 <key u32>        host ack of completion (device echoes it)
```

**The device streams**: one `82` request is enough — it sends every chunk back to
back and then `84`. Re-requesting per chunk makes it re-serve the tail (chunks for
offset 20900 came back while 4180 was outstanding). Read the stream to completion,
bucket chunks by offset, then send `85`.

Nothing arrives before a take exists: the key is only offered for a recording the
device considers unsynced, and it disappears once a transfer has been acked.

Measured: a 14-second recording = 15 chunks = **31,913 bytes** (2.28 KB/s ≈ 18 kbit/s);
a 28.6-second recording = 22,511 bytes, verified `OggS` end to end.

> **Caveat:** the Android snoop buffer drops packets during the bulk phase, so only the
> control frames in a capture are complete. A client reads the stream directly and never
> needs the log.

### Record control — just transfer mode

Verified on hardware 2026-11-11 with the device's LED watched:

```
attr 0x16 = 02     start a take, hold the red light
attr 0x16 = 00     stop
```

Nothing else is required or wanted. A pure cycle (`0x16=2 … 0x16=0`) recorded a take
whose length matched the hold, and a 15 s hold produced a 43.5 s take that kept growing
while we stayed connected.

**The vendor's extra writes cancel a take.** The app writes `0x13` (context, state 04),
`0x11` (file id), `0x17 = 1` at *connect*, then `0x16 = 2`, `ch 8008 81 01 00 01`
(record), `ch 8008 80 01 00 01` (key). Sending those registration writes or the channel
`0x8008` pair immediately after the start makes the LED blink once and nothing records —
which is exactly the failure mode we chased for hours. Channel-`0x8008` payloads also
need a CRC16 (`81010001 b83c`, `80010001 b9c0`); without it the device ignores them.

Note on the client: the "publish a take" fallback that cycles `0x16` must be suppressed
while a take is running, or pulling stops the recording.

Observation, not yet explained: the device kept offering older ~10.5 kB takes on repeated
pulls instead of the newest one, as if a take is only retired after the vendor app's cloud
sync rather than our `85` ack.

### Settings and status table (channel `0x0021`)

Reading `00 00 00` on channel `0x0021` returns the device's own settings/status table as
TLV. Mappings below marked *verified* were confirmed by watching the vendor app under HCI
snoop and cross-checking its own display:

| attr | meaning | evidence |
|---|---|---|
| `0x01` | battery, percent | *verified* — `0x47` = 71 %, same number the app shows |
| `0x04` | mic gain, dB | *verified* — `0x18` = 24 dB; app writes it from its Mic Gain slider |
| `0x05` | noise reduction, 1/0 | *verified* — snoop shows `0x05=00` at 22:06:11 then `01` at 22:06:32 while the app's toggle moved |
| `0x0b` | session / release flag | 0 hands the device back to the vendor app |
| `0x0d` | 2 bytes (`01 0e`) | unknown |
| `0x15` | storage: **total KB, then free KB** (u32 LE each), 2 reserved bytes | *decoded from captures* — total held at 7,675,904 KB while free fell `7,673,856 → 7,673,792` KB as takes were recorded; 7.68 GB decimal matches the advertised 8 GB |
| `0x16` | record / transfer mode | 2 starts a take, 0 stops |
| `0x21` | cloud endpoint string | vendor app writes `100.51.32.75:8080` at connect |
| `0x28` | 0/1, meaning unknown | toggles with page state |

**VCS gain is still unmapped.** The vendor app exposes it as a Low/Medium/High slider, but:
its page writes nothing when opened, injected taps/swipes/motion events do not move the
slider (custom gesture handling), and writing candidates (`0x06..0x09`) is not reflected in
what the app displays. `0x08` and `0x09` *are* writable and mirrored — `0x08=02` set both —
but the app still reported "Medium", so neither is VCS.

To finish it: drive the real slider by hand once with snooping on, or run the app on a
phone rather than this tablet's desktop window. The app deliberately does not guess: it
writes a candidate, re-reads this table, keeps the change only if the device reflected it,
and otherwise restores the old value and says the firmware refused.

### Payload integrity

Every file payload carries two checksums, both verified before use:

```
aa | crc32(body) u32le | type | len u16le | body | crc16(payload up to here)
```

Frames that fail either one are dropped and counted (`corruptFrames`), never written into
the audio. The 17-byte frame envelope has its own 8-bit sum, checked by the assembler.

### Round trip verified

open app → connect (no auth) → `CMD_GET_INFO` TLV (name, SN, fw v1.14, battery 83 %,
storage counters) → settings read (mic gain 24 dB, NR on, VCS medium) → **write** mic gain
18 dB → restore 24 dB → file list refresh → open 5 s recording → record 14 s on the device →
chunked pull of the new file.
