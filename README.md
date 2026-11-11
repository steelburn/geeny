# Geeny — unofficial Boya Notra Neo client

**Geeny** is the app; the `notra/` Python package and the protocol names keep the
recorder's own name (Boya Notra Neo). It talks to the device directly over BLE. No vendor
app, no cloud, no account. Protocol recovered from the vendor's own `libcfdlink.so` and
verified against hardware — see `research/PROTOCOL.md`.

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

## Android app (Flutter)

`app/` — the same protocol in Dart, for phones and tablets. Same design system as the
web console (`DESIGN.md`), same frame codec, same CRC tables.

```bash
cd app
flutter test                     # 34 tests: codec, CRCs, session flow, notes, storage
flutter build apk --debug        # -> build/app/outputs/flutter-apk/app-debug.apk
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

The Android package id is `dev.geeny.app` (Dart package `geeny_app`); the launcher label is
**Geeny**.

It scans and connects (no pairing), sends the heartbeat every 4 s so commands are accepted,
shows the device's battery (`attr 0x01`), toggles noise reduction (`attr 0x05`) and mic gain
(`attr 0x04`), records and stops takes (`attr 0x16`), fetches the current take
into the app's documents directory as `notra-<timestamp>.ogg`, and plays saved takes back
in-app (play/pause, seek, position). Settings and diagnostics are folded away behind
disclosures so the front page stays about recording. The status bar also shows the
recorder's own free capacity (`attr 0x15`), so you know whether the next take fits.

The launcher icon is generated, not hand-drawn: `scripts/make_icon.py` draws the mark (forest
stock, a paper **G** for Geeny, one sage recording light) and writes the legacy mipmaps plus
the adaptive-icon vector. Re-run it after changing the tokens.

Every pulled payload is checksum-verified (crc16 + crc32); damaged frames are dropped and
counted, never written into the audio.

## Transcription and summaries

Boya OS does this in its cloud (Azure Speech + a server-side LLM, metered in minutes) — see
`research/VENDOR_AI.md`. This project keeps it on your own machine instead:

```bash
# one-time: a dedicated env, because the local LLM needs a prebuilt wheel
uv venv .venv-ai
uv pip install --python .venv-ai/Scripts/python.exe     faster-whisper soundfile numpy     llama-cpp-python --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu

# list summary models, then fetch the one that fits your patience
.venv-ai/Scripts/python.exe scripts/fetch_model.py --list
.venv-ai/Scripts/python.exe scripts/fetch_model.py qwen2.5-3b-instruct-q4_k_m

.venv-ai/Scripts/python.exe scripts/ai_server.py
adb reverse tcp:8765 tcp:8765        # tablet reaches it at 127.0.0.1:8765 over USB
```

**Bigger summary models: do they help?** For *summaries*, yes, up to a point — a 3B writes
tighter sections and misses fewer actions than 1.5B; 7B is better again but roughly 4× the
wait per take on CPU. They do **not** improve transcription accuracy: that comes from the
whisper size (`tiny/base/small/medium`), a separate setting. `scripts/fetch_model.py` offers
1.5B / 3B / 7B Qwen and a 3B Llama; any `.gguf` in `~/.cache/notra/models/` also shows up in
the picker. CPU sweet spot: **3B**.

The app's **Summary → On this machine** picker lists the whole catalog, not only what is
installed: a model that is missing shows its size and downloads from the service (with a
progress line) when tapped, then becomes selectable. The CLI path is still
`scripts/fetch_model.py <name>`.

Summaries come from the chosen local GGUF (`llama.cpp · qwen2.5-3b`) when present, then a
local OpenAI-compatible server if one is running, and only then the extractive fallback —
`GET /health` reports which. Set `NOTRA_LLM_MODEL` to use a different GGUF.

**Speech and summary are routed independently.** Each half is either *on this machine* or an
*external service*, so local whisper + an external summary model (or the reverse) is a normal
setup:

- **On this machine** — whisper `tiny/base/small/medium` for speech; any GGUF in
  `~/.cache/notra/models/` for summaries (or `extractive`, or the service default). Larger
  whisper sizes are slower but handle accents and code-switching better.
- **External service** — any OpenAI-compatible API (OpenAI, Groq, LM Studio, llama.cpp):
  base URL, API key, and the speech *or* summary model. The endpoint fields sit under the
  half you switch to External, so Speech never shows a model field without them. Audio and
  transcripts go there and are billed by it; the key lives in the app's preferences, not a
  system keystore.

There is **no local-service-URL field**. The app owns that address: it uses the built-in
default `http://127.0.0.1:8765` (or `--dart-define=NOTRA_AI_URL=http://192.168.1.20:8765` at
build time) and probes the usual candidates on first use, remembering whichever answers
`/health`. `adb reverse` is still enough on USB, and a LAN address needs no typing.

Tap the notes icon on any take in the app: it posts the `.ogg` to that service (or the
external API), shows the transcript with timestamps (tap a line to seek the player) and a
template summary (meeting / lecture / notes). No account, no upload to a vendor unless you
chose an external service.

**Nothing is transcribed or summarised twice.** Transcripts and summaries are written next to
the take as `<take>.ogg.notes.json` and restored on launch. Opening a take that already has a
transcript reuses it, and a summary for the selected template is not regenerated. Only
**Redo** forces transcription again; switching the template re-runs *just* the summary.

**Summary shape is fixed by the template.** The model may rename or reorder sections; the
service and the app both map the result onto the template's headings and order
(`Overview` / `Decisions & actions` / `Key points`, `Overview` / `Key concepts` / `To review`
or `Overview` / `Key points`) and strip list markers. Older sidecars render in that order too,
so the same take looks the same across models.

Each take shows its **length and size**, and once it has been transcribed, a generated
**title** (editable — tap it in the notes sheet) with the filename underneath. Tapping a row
offers **Play / Transcribe & summarise / Move to project / Delete**.

Projects are a local index (`library.json`) with filter chips above the list: **All**,
**Unfiled (n)** and each project, so "All" is never the only way to tell takes apart. No
folders are moved on disk.

The notes sheet gives you what you need for work or study: **Copy summary**, **Copy
transcript**, **Export .md** (Android share sheet), and **Redo** — plus **Speaker 1 /
Speaker 2** labels when the optional diarizer is installed.

Setup lives in the **panel on the right** (`⚙` in the header): device settings, transcription
config and diagnostics, out of the way until needed.

From the command line, without the app:

```bash
uv run --with faster-whisper --with soundfile --with numpy python -m notra summary take.ogg --template meeting --save
```

Summaries are extractive by default — real sentences from the transcript, ranked, nothing
invented. If a local OpenAI-compatible server is running (LM Studio on :1234, Ollama on
:11434, llama.cpp on :8080) the same call produces an abstractive summary instead.

## Search and ask across your takes

Once a take has a transcript, its text is searchable — and askable. The magnifier in the
header opens one sheet with two modes:

- **Search** — BM25 over every transcript line and every summary bullet, with the take's
title, project and date indexed too. A hit shows the take, the timestamp and the passage;
tapping it opens the transcript at that moment (loaded, not playing).
- **Ask** — a question is answered by the same local GGUF that writes the summaries, using
only the six best-matching passages, with `[n]` citations back to the take and timestamp.
No model installed? The matching passages themselves are shown and labelled *extractive* —
nothing is invented either way.

The app pushes the text it already has (transcripts + summaries) to the service, which keeps
an in-memory index; the audio never leaves the device and neither does the text. Search is
purely local, so it also works when both AI halves are routed externally — but not when the
service is down.

```bash
python -m notra find "sampling plan" --library path/to/takes
python -m notra ask  "who owns the sampling plan?" --library path/to/takes
```

`<take>.ogg.notes.json` sidecars plus `library.json` are all the CLI needs, so a PC library
is searchable without the app.

## Import from Boya OS (and anywhere else)

Boya OS keeps recordings in its own account; there is no import API and no local file to
steal. What it does have is **Share** and **Export** — so Geeny registers as an Android
share target for audio and for transcript files:

1. In Boya OS: **Share → Geeny** for a recording, or **Export audio** and pick the file.
   Ogg Opus transcribes locally; MP3/M4A play here but need an external speech service.
2. **Export transcript** as TXT, Markdown or SRT (DOCX and PDF are not readable) and share
   that too. It is attached to the take with the same name, or kept as a *transcript-only*
   take when the audio stayed in the cloud — searchable, readable and exportable, just not
   playable.

The takes header has **Import → Choose a file** for exports that ended up in Downloads.
Everything lands in the app's own library; nothing is uploaded.

## Housekeeping — models on the serving machine

Setup → **Models on this machine** lists every download with its size and one delete button:

- summary GGUFs (`~/.cache/notra/models/`)
- whisper weights (`~/.cache/huggingface/hub/models--Systran--faster-whisper-*`)
- interrupted `.part` downloads

It shows the total, deletes on the machine that runs the service, and says what re-downloads
if you change your mind. The same thing from a shell:

```bash
python scripts/fetch_model.py --storage
python scripts/fetch_model.py --delete qwen2.5-3b-instruct-q4_k_m
python scripts/fetch_model.py --delete whisper:small      # free 486 MB
python scripts/fetch_model.py --prune-parts
```

**Record / Stop** is one attribute: `0x16 = 2` starts a take, `0x16 = 0` stops it
(verified on hardware, LED confirmed). Extra vendor writes around the start cancel it.

The session layer is transport-agnostic (`Link`), so `test/session_flow_test.dart` drives
the whole client against a fake device answering with payloads copied from the live
capture - the handshake is exercised without a radio.

## Status

| Capability | State |
|---|---|
| Connect (no pairing, no bond, no auth) | **verified** |
| Frame codec + 8-bit checksum | **verified** — 732 live frames + round-trip tests |
| Heartbeat / keep-alive | **verified** — required, see below |
| Read name, serial, attributes | **verified live** |
| Recorder storage capacity (`attr 0x15`, total/free KB) | **verified live** — 7.7 GB free of 7.7 GB shown in the app |
| Write attributes (mic gain) | **verified** — 24 → 18 → 24 dB on hardware |
| Activate the device for recording (`attr 0x12 = 1`, `attr 0x0b = 1`) | **verified** — recorded with no vendor app connected |
| CRC16 for writes | **solved** — tables extracted from the SDK |
| Pull a recording (chunks -> Ogg Opus) | **verified** — four takes, 10.6-22.5 KB, all valid `OggS` |
| Arm the device so it records without the vendor app | **verified** (`attr 0x12 = 1`, `attr 0x0b = 1`) |
| Deactivate / hand the device back to the vendor app | **verified** (`attr 0x0b = 0`, `attr 0x12 = 0`) |
| Start/stop a recording from the client | **verified** — `attr 0x16 = 2` starts, `0x16 = 0` stops (LED confirmed) |
| Publish a finished take for transfer | **verified** — cycle `attr 0x16` 2 → 0, then poll |
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
notra/frame.py        frame + TLV codec (pure, no I/O)
notra/crc.py          CRC16 tables from the SDK
notra/transport.py    BleTransport (bleak) and ReplayTransport (btsnoop)
notra/client.py       session: heartbeat, attributes, settings, file pull
notra/ai.py           whisper + summaries, local GGUF catalog, model housekeeping
notra/search.py       BM25 index over transcripts/summaries + cited answers
notra/cli.py          command line (scan, info, pull, transcribe, summary, find, ask)
tests/test_frame.py   offline protocol regression tests
tests/test_search.py  retrieval, citations and library-loading tests
app/                  Flutter client (see app/README.md)
app/lib/import/       share-sheet import + Boya OS export parsers (TXT/MD/SRT/JSON)
app/lib/ui/ask_sheet.dart      search / ask sheet
app/lib/ui/models_section.dart model housekeeping panel
web/index.html        Web Bluetooth console
scripts/ai_server.py  local transcript/summary/search service
scripts/fetch_model.py  download, list or delete a summary GGUF
scripts/make_icon.py  regenerate the launcher icon + favicon
```

Interoperability research on hardware I own. Not affiliated with Boya/Jiayz; no vendor
code or binaries are redistributed.
