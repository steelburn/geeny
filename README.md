# notra — unofficial Boya Notra Neo client

Talks to the device directly over BLE. No vendor app, no cloud, no account.
Protocol recovered from the vendor's own `libcfdlink.so` and verified against hardware —
see `research/PROTOCOL.md`.

> **Continuing from a previous session? Read `HANDOFF.md` first** — state, gotchas and
> the one open problem are all written down there.

```bash
uv run --with bleak python -m notra scan          # find the device
uv run --with bleak python -m notra info          # name / SN / attributes   (works)
uv run --with bleak python -m notra gain 18       # mic gain (dB)
```

Offline (no hardware):

```bash
python -m notra selftest research/capture/extadd/FS/data/misc/bluetooth/logs/btsnoop_hci.log
python -m notra frames   <btsnoop> --limit 20
python tests/test_frame.py
```

## Web app

`web/index.html` — single file, no build step, Web Bluetooth:

```bash
cd web && python -m http.server 8740     # open http://localhost:8740 in Chrome/Edge
```

Connect -> pick "Boya Notra Neo". The page sends the heartbeat, reads name + serial,
lets you write mic gain, and can pull a recording by id (saves an `.ogg`).
Windows and Android Chrome; Safari has no Web Bluetooth.

## Status

| Capability | State |
|---|---|
| Connect (no pairing, no bond, no auth) | **verified** |
| Frame codec + 8-bit checksum | **verified** — 732 live frames + round-trip tests |
| Heartbeat / keep-alive | **verified** — required, see below |
| Read name, serial, attributes | **verified live** |
| Write attributes (mic gain) | **verified** — 24 → 18 → 24 dB on hardware |
| Activate the device for recording (`attr 0x12 = 1`, `attr 0x0b = 1`) | **verified** — recorded with no vendor app connected |
| CRC16 for writes | **solved** — tables extracted from the SDK |
| Pull a recording (chunks -> Ogg Opus) | **implemented**; end-to-end untested (device memory was wiped during capture) |
| List recordings | **not exposed over BLE** — the vendor app's list comes from its cloud sync |
| Wi-Fi "Fast Transfer" | not examined |

Recordings are **Ogg Opus, mono, 16 kHz** — no codec work needed.

## Heartbeat — the thing that unlocks the device

The device ignores every command until it sees a valid heartbeat on channel `0x0000`.
Two separate sequences are involved; mixing them up silently freezes the command channel
(telemetry keeps flowing, so it looks connected):

```
msg_id  = 0x0015, 0x0016, ...     frame header, +1 each beat
counter = 0xfc15, 0xfc2d, ...     inside the payload, +0x18 each beat
payload = 00 60 09 00 02 0a <counter u16> <time u32> 2c
dst = 00 00 00 00 broadcast   channel = 0x0000   flags = 0x12
```

Then `get_info` is just an empty frame on channel `0x0015`; attribute reads are `00 00 00`
on a channel, answered with `00 <value> <crc16>`.

Binding is *not* a gate: this client works on a factory-reset unit and on one bound to the
phone. Windows BLE pairing is unnecessary.

## Channel map (as far as we know)

| Channel | Meaning |
|---|---|
| `0x0000` | heartbeat / telemetry stream |
| `0x0001` | identity blob (name + flags) |
| `0x0010` | status / usage counters |
| `0x0015` | `CMD_GET_INFO` |
| `0x0017` | serial number |
| `0x0018` | device name |
| `0x001e` | settings (TLV attr `0x04` = mic gain, `0x11` = selected file id) |
| `0x0021` | capabilities TLV |
| `0x0022` | periodic status |
| `0x8007` | file data (chunk request/response) |
| `0x8008` | file control (returns the current file key) |

## CRC16

Attribute writes and file frames end with a 2-byte CRC16 that is not a standard variant.
The tables live in `libcfdlink.so` at `0x1a825` / `0x1a925`; both are embedded in
`notra/crc.py` and `web/index.html` (reflected, output little-endian). Verified against:

```
crc16(00 "Boya Notra Neo") = c9 64      device reply
crc16(04 01 12)            = c0 5c      app write, 18 dB
```

File frames use both checksums: `aa | crc32(body) LE | body | crc16` (CRC32 = zlib).

## File transfer — latest recording

The 34-character id in the vendor app is a *cloud* artefact. Over BLE you only need the
4-byte file key. Observed working sequence (from a live app capture):

```
settings  attr 0x13 = <6 bytes>        written around a recording (start + stop)
settings  attr 0x16 = 2                "transfer mode"   [then 0 to close]
0x8008    81 01 00 01                  -> 81 08 00 00 00 00 00 00 00 00 00 2c
0x8008    80 01 00 01                  -> 80 04 00 b365f36a        file key
0x8007    81 04 00 <key>               -> 81 18 <hash 16B> <size u32> <chunks u32>
0x8007    82 08 00 <key> <offset u32>  -> aa | crc32 | 82 34 08 <seq> <off> <len> <data> | crc16
0x8007    84 04 00 <key>               -> close
```

2090 bytes per chunk; the stream is Ogg Opus (mono, 16 kHz).

**Open question:** the key is only offered for a recording the device considers
*unsynced*. Replaying the bytes later (after the vendor app had already synced) yields no
key, and driving `attr 0x16 = 2` alone is not enough to reopen it. To land this, capture a
session where the app itself records **over BLE** and pulls immediately — that shows whether
`attr 0x13` carries a session/timestamp the device keys the pending file on.

## Layout

```
notra/frame.py      frame + TLV codec (pure, no I/O)
notra/crc.py        CRC16 tables from the SDK
notra/transport.py  BleTransport (bleak) and ReplayTransport (btsnoop)
notra/client.py     session: heartbeat, attributes, settings, file pull
notra/cli.py        command line
tests/test_frame.py offline regression tests
web/index.html      Web Bluetooth console
```

Interoperability research on hardware I own. Not affiliated with Boya/Jiayz; no vendor
code or binaries are redistributed.
