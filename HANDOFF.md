# Handoff — Geeny (Boya Notra Neo client)

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

## 3. File pull — solved (was the one open problem)

File traffic is a normal `0x55` frame (`flags 0x10`/`0x11`) on channel `0x8007` whose
payload is `aa | crc32 | type | len u16 | body | crc16`. The old client sent these raw
and on channel `0x8008`, which is why the device never answered.

```
86 02 00 e7 03                    poll -> 86 0c 00 <key u32> ...   (or 90 01 00 01)
81 04 00 <key>                    open  -> 81 18 00 <hash16> <size u32> <chunks u32>
82 08 00 <key> <offset u32>       request the stream once
   ... device streams every chunk (82 34 08 <seq> <off> <len> <data>) ...
84 04 00 <key>                    device: complete
85 04 00 <key>                    host ack (device echoes)
```

Verified end to end on hardware: `22511` bytes pulled, `OggS` magic, 28.62 s of Opus
(`scripts/pull_latest.py`, and the Flutter app's Pull latest). The key only exists for a
take the device has not handed over yet — after a completed pull it answers
`90 01 00 01` / no key, which is correct behaviour, not a failure.

Pulls verified on four takes: 22,511 B / 28.6 s, 12,781 B / 14.5 s, 12,658 B / 14.3 s,
10,622 B / 11.3 s - all valid `OggS`.

**A take must be published before it can be pulled**: a poll right after recording returns
`90 01 00 01`; the key only appears after transfer mode is cycled (`0x16 = 2 … 0x16 = 0`).
Both clients now do that fallback automatically (capture 2026-11-11 20:56).

**Record/Stop works — it is just transfer mode** (verified 2026-11-11 with the LED
watched): `attr 0x16 = 2` starts a take and holds the red light, `attr 0x16 = 0` stops.
The vendor's registration writes (`0x13`, `0x11`, `0x17`) and the channel-`0x8008`
`81/80` pair are its *session setup*; sending them right after a start makes the light
blink and nothing records. The app now writes only `0x16`, and Pull latest suppresses its
transfer-mode cycle while a take is running so it cannot stop it.

Earlier conclusion (kept for the trail): a client replaying the full vendor sequence never
got a file allocation — that was the extra writes killing the take, not firmware policy. The real start is
`0x16 = 2` + `ch 8008 81 01 00 01` (the capture also shows `80 01 00 01` then a key), and
`0x16 = 0` stops. Replaying that with the correct CRC16 got the device's `81 08 … 2c` ack
but never a file allocation (no key, no red light), across variants: vendor file id,
primed channel reads, endpoint `0x21`, clock-matched context tick. A third-party client
cannot start a take. The app therefore exposes Arm / Pull latest / Deactivate only, and
says so in the UI.

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
3. Flutter app: **built and running** - see section 9.

---

## 9. Flutter app (`app/`)

Built in the session after this handoff. Target is the Android tablet (Lenovo TB336FU,
Android 16 / SDK 36, 800x1280 dp).

| Path | What it is |
|---|---|
| `app/lib/protocol/` | Frame codec, CRC16/CRC32 (generated from `notra/crc.py`), frame assembler |
| `app/lib/ble/link.dart` | `flutter_blue_plus` transport: scan by name, connect, notify -> frame stream |
| `app/lib/ble/notra_client.dart` | Session ops mirroring `notra/client.py` (heartbeat, attrs, pull) |
| `app/lib/state/session.dart` | UI state, 4 s keep-alive timer, log ledger |
| `app/lib/theme/`, `app/lib/ui/` | Tokens and the single-screen console |
| `DESIGN.md` | Shared design system - web console and app use the same tokens |

Verified offline: `flutter test` -> 19/19 (codec, CRC16 against device-verified `c0 5c` /
`60 55`, TLV, split-frame reassembly, heartbeat sequences `0x0015` / `0xfc15 + 0x18`,
info read, gain write CRC, 2090-byte chunk pull + close). `flutter analyze` clean.

Verified **live on hardware** (Lenovo tablet, 2026-11-11):

```
link up · mtu 498 · 05:A5:3D:A9:58:7B
name "Boya Notra Neo" · serial GL3410314055W · 2 attributes
rx ch 0015 29B · rx ch 0018 17B · rx ch 0017 16B · rx ch 000e 6B (acks)
mic gain -> 24 dB (attr 0x04)          write accepted; device echoes 000401c3 on ch 001e
attr 0x00 = 0000000f0000041000000001   attr 0x0a = (empty)
```

So: scan, connect (no pairing), heartbeat, identity read, attribute write and the frame
ledger all work from the app. Keep-alive runs at 4 s and the link stayed up across a
20 s idle window.

Pull latest: **verified end to end** (22511 bytes, valid Ogg Opus, saved to the app's
documents directory).

Record controls in the app: **Arm** (0x12=1, 0x0b=1), **Pull latest**, **Deactivate**
(0x0b=0, 0x12=0 -> "released", verified to hand the device back to the vendor app).
**Record/Stop** toggles `attr 0x16` (2/0) and works on hardware. **Takes** lists pulled
files with in-app playback (just_audio): play/pause, seek, position/duration, all verified.
Open detail: the device re-offers older ~10.5 kB takes on repeated pulls; retirement looks
tied to the vendor app's cloud sync rather than our `85` ack.

New research tools: `scripts/pull_latest.py` (pull + validate), `scripts/watch_take.py`
(poll for a take), `scripts/decode_record_evidence.py <btsnoop>` (timeline of settings
writes and file-channel commands, flags unfamiliar attributes).

### Toolchain (installed this session, not on PATH by default)

```
export PATH="/c/Users/USER/flutter/bin:$PATH"
export JAVA_HOME="C:\Users\USER\jdk-17.0.21+9"
export MSYS_NO_PATHCONV=1
```

Flutter 3.47.9, JDK 17, Android SDK at `C:\Users\USER\android-sdk`
(platform 36, build-tools 36.0.0, NDK 28.2.13676358). Already configured via:

```
flutter config --android-sdk "C:\Users\USER\android-sdk" --jdk-dir "C:\Users\USER\jdk-17.0.21+9"
```

`flutter_blue_plus` 2.3.15 requires `license: License.nonprofit` on `connect` - this is a
personal, non-commercial interoperability tool. The license is set in `link.dart`.

---

## 11. Transcription and summaries (2026-11-11)

**Vendor first:** Boya OS has no on-device AI. `research/VENDOR_AI.md` documents what the APK
contains: base `https://ai.boyaos.com/prod-api`, `/api/asr/transcribeAndSummarize`,
`/api/asr/pre|fast|again/transcribe`, realtime via `/api/asr/azure/realtime/token` (Azure
Speech), summaries via `/api/asr/save/summary` + `/api/operations/selectCategoryWithTemplates`
(40+/60+ templates: project meeting, university lecture minutes, classroom interaction), S3
presigned uploads, and a minutes-based quota ("Insufficient transcription time").

Nothing to clone: the value is a service. So we built the local counterpart.

| Piece | Path | Notes |
|---|---|---|
| `notra/ai.py` | transcribe / summarise / render | faster-whisper + libsndfile (Opus), template summary, optional LLM |
| `scripts/ai_server.py` | HTTP service on :8765 | `/health`, `/transcribe` (raw ogg), `/summarize` |
| `app/lib/ai/ai_client.dart` | Dart client | probe, transcribe, summarize |
| `app/lib/ui/notes_sheet.dart` | notes sheet | template chips, summary, timestamped transcript that seeks the player |
| `notra cli transcribe|summary` | CLI | `python -m notra summary take.ogg --template meeting --save` |

Verified: service transcribes a 14 s take in ~2.4 s (CPU, whisper `base`, int8); the app's
notes sheet returns a transcript + extractive summary over `adb reverse`; transcript rows
seek the player.

Known limits / next steps:

- **Summaries run locally now.** `llama.cpp` + `qwen2.5-1.5b-instruct-q4_k_m.gguf` (1.1 GB,
  CPU, ~4 s warm for a short take) — installed in `.venv-ai` from the prebuilt wheel index,
  model at `~/.cache/notra/models/`. `ai.summarize` tries: local OpenAI-compatible server →
  local GGUF → extractive. `GET /health` reports `local_llm`. Note the app needs the service
  started from `.venv-ai`, not `uv run`.
- Extractive fallback still exists and is still thin on very short takes; that is expected.
- `base` struggles with Malay/English code-switching (a real take came back as
  "di silis atuna rekording kita buat"). **Solved by the model picker** (below);
  `small`/`medium` are selectable in the app and passed as `?model=` to the service.
- **Model picker**: Settings → Transcription → whisper `tiny/base/small/medium`, persisted in
  preferences. `/transcribe?model=small` verified in the service log.
- **External services**: Settings → Transcription → *External service* on either half routes
  that job to any OpenAI-compatible API (`/audio/transcriptions` with `verbose_json`, then
  `/chat/completions` returning JSON sections). Fields: base URL, key, and that half's model.
  Untested against a live provider (no key on this machine) — the error path is wired
  (401 → "External service rejected the API key"). Speech and summary became independent in
  §15.
- `scripts/ai_server.py` caches one WhisperModel per size; `/health` lists available and
  loaded models, plus the summary-model catalog.
- Notes are persisted next to each take as `<take>.ogg.notes.json` since §15, so reopening a
  take (or relaunching the app) never repeats transcription or summarisation.
- For a shipped app the tablet should reach the service over the LAN, not `adb reverse`.
  §15 removed the URL field: the app discovers the address (or is built with
  `--dart-define=NOTRA_AI_URL=…`).

---

## 12. Tidy-up round (2026-11-11, later)

Six changes requested, all in:

1. **Per-mode model config.** `AiSettings` now holds `localSpeech` / `localSummary` and
   `externalSpeech` / `externalSummary`; switching modes does not clobber either. Local
   summary can be a specific GGUF, the service default, or `extractive`
   (`prefer_llm: false`). The service takes `summary_model` and lists `local_llms` in
   `/health`.
2. **Setup moved aside.** Settings / Transcription / Diagnostics live in the right-hand
   drawer (`⚙` in the header). The page is now: header, actions, status card, takes.
3. **Footer removed** ("Protocol recovered from the vendor SDK …").
4. **Redo** in the notes sheet re-runs transcription + summary (`generateNotes(force: true)`);
   changing the template re-runs just the summary.
5. **Speaker labels.** `notra/diarize.py`: ECAPA-TDNN embeddings per whisper segment
   (SpeechBrain) + agglomerative clustering over cosine distance, anonymous "Speaker N".
   Guarded by `SAME_SPEAKER_SIM` (0.45) so one voice is never split into two. Optional deps:
   torch/torchaudio (CPU index) + speechbrain + scikit-learn. Without them the service
   reports `speakers: false` and the transcript simply has no labels.
   Windows note: SpeechBrain's default symlink strategy fails without privileges — the
   encoder is loaded with `local_strategy=LocalStrategy.COPY`.
6. **Projects.** `projects.json` next to the takes maps file → project; filter chips above
   the list; "Move to project…" in the row sheet (pick existing or type a new name).

Verified on the tablet: drawer opens with device + transcription sections, the 48 s take
transcribed with `small` (Malay, much better than `base`) and summarised by the local GGUF
(`POST /transcribe?model=small` then `POST /summarize`), redo button present, projects and
delete in the row sheet.

Known limits: speaker labels are per whisper segment, not word-level, and only when the
diarizer is installed; two very short segments will not be split (guard) and a long
single-speaker take can still be over-split if the voice drifts.

---

## 13. Practical use: titles, copy/export, unfiled (2026-11-11, later)

- **Titles.** `POST /title` on the service: 3-6 word title from the local GGUF, or a lead-in
  fallback when the transcript is under ~8 words or no GGUF is present. Generated once, right
  after a new summary (`generateTitle`), stored in `library.json` and shown bold above the
  filename. Editable from the notes sheet header (pencil).
- **Copy / export.** Notes sheet: Copy summary, Copy transcript, Export `.md` (writes a
  markdown file to temp and opens the Android share sheet via `share_plus`). The markdown
  carries title, engine line, summary sections and the timestamped transcript, with speaker
  labels when present.
- **Unfiled filter.** Filter chips are All / Unfiled (n) / each project. Counts come from
  `unfiledCount`; filtering is a pure function (`filterTakes`) with unit tests, because tap
  testing in this harness is unreliable.
- `projects.json` became `library.json` (projects + assignments + titles); the old file is
  migrated on first load.

Tests: 22 (19 + 3 filter tests).

---

## 14. Design review + fixes (2026-11-11, final pass)

Reviewed with the ux-design method: `ux_audit` green on all four gates (contrast, tokens,
states, slop tells) before and after; `DESIGN.md` linted clean.

P0 fixed:

- **Back closed the app while Setup was open.** `HomePage` is stateful, tracks
  `onEndDrawerChanged`, and wraps the Scaffold in `PopScope(canPop: !drawerOpen)`. Verified:
  back now closes the panel and the activity keeps focus.
- **Touch targets.** Icon buttons 48 dp, steppers and compact chips 44 dp, via
  `Tokens.target` / `Tokens.targetCompact`.

P1 fixed:

- **Status bar instead of a 130 px empty card.** One line idle ("Not connected · Tap Connect
  to pair"), expands while recording with a live `MM:SS` counter (1 s ticker in `Session`),
  while transferring with a progress bar, or when there is a notice.
- **User-facing copy.** Header subtitle, settings hints, VCS/NR descriptions and the takes
  footer now speak intent; protocol detail moved into Diagnostics. No more
  "Attribute 0x04 on channel 0x001e" in the UI.
- **Untitled takes read as dates** ("11 Nov · 05:48") with the filename as the second line;
  the raw `notra-…T0548.ogg` is no longer the primary label.
- **Active row state**: whole row tints `accent-soft` with a 2 px accent rule on the left.

P2 fixed:

- **Type scale collapsed to five sizes** (34/20/15/13/12); every inline `fontSize:` is gone
  (`grep fontSize: lib | wc -l` → 0).
- **Reduced motion**: `Disclosure` checks `MediaQuery.disableAnimations` and drops its
  animations when asked.
- **One chip component**: `ChoiceChipButton` with focus ring, hover, pressed, disabled and
  `Semantics(selected:)`; replaces both the Material `ChoiceChip` and the ad-hoc `_Chip`.
- **`elev2`** for sheets (via `SheetSurface`); `elev1` stays for cards.
- **Notes sheet split**: Summary | Transcript segmented control instead of two stacked,
  equally-weighted sections.

Still unverified: the recording counter on real hardware (device was offline at capture
time) and portrait layout (tablet locked landscape in desktop mode).

---

## 15. Settings cleanup, independent AI routing, cached notes (2026-11-11, final)

1. **The local service URL is gone from the UI.** `AiSettings.localUrl` is app-owned: it
   defaults to `http://127.0.0.1:8765`, is overridable at build time with
   `--dart-define=NOTRA_AI_URL=http://192.168.1.20:8765`, and `AiClient` probes a short
   candidate list (`127.0.0.1`, `localhost`, `10.0.2.2` emulator) on `/health`, persisting
   whichever answers. The panel shows the resolved address as a read-only caption. Nothing to
   type for `adb reverse`, and no URL field to lose on a LAN.
2. **Speech and summary route independently.** `AiMode` became `AiBackend` plus
   `speechBackend` / `summaryBackend`; the old `ai.mode` value migrates both. Local speech +
   external summary (and the reverse) is a valid setup: `AiClient` dispatches per half,
   `probe()` checks every backend in use, and the title follows the summary backend.
3. **Bigger summary models are first class.** `notra/ai.py` has `MODEL_CATALOG` (Qwen
   1.5B / 3B / 7B, Llama 3.2 3B); `scripts/fetch_model.py --list` and
   `scripts/fetch_model.py <name>` download into `~/.cache/notra/models/`; `/health` reports
   the catalog and which files are installed. Accuracy call: bigger GGUFs improve the *notes*,
   not transcription — whisper size owns that — and 3B is the CPU sweet spot.
4. **No repeated work.** Notes are persisted beside each take as `<take>.ogg.notes.json`
   (`TakeNotes.toJson/fromJson`) and restored in `Takes.refresh()`. `notesAction()` is the
   pure decision (transcribe+summarise / summarise only / none), so opening a take with a
   transcript never re-transcribes, and a matching summary never re-runs. Only Redo
   (`force: true`) repeats both; changing the template re-runs just the summary.
5. **Launcher icon.** `scripts/make_icon.py` draws the mark (forest stock, a paper **G**,
   one sage recording light) and writes the five legacy mipmaps, the adaptive icon,
   `drawable/ic_launcher_foreground.xml`, `values/colors.xml`, `app/assets/brand/icon.svg`
   and `web/favicon.svg`. Regenerate after touching the palette.
6. **Recorder storage in the UI.** `attr 0x15` turned out to be total then free capacity as
   u32 LE **kilobytes** (2 reserved trailing bytes). Decoded from the capture set: total
   stayed 7,675,904 KB while free fell 7,673,856 → 7,673,792 KB as takes were added. The
   status bar now shows `7.7 GB free` (decimal GB, matching the 8 GB marketing figure) with
   the total in its tooltip, and Diagnostics has a `storage` fact.

Verified on the Lenovo tablet: debug APK built; the launcher resolves
`res/mipmap-anydpi-v26/ic_launcher.xml`; Setup shows the removed URL field, independent
Speech / Summary routing and the GGUF picker; switching Summary to External reveals the
endpoint fields; the 48 s take transcribed (`POST /transcribe?model=small`) then summarised;
closing/reopening the take, and force-stop + relaunch, produced **zero** new `/transcribe` or
`/summarize` calls (5/5 before and after) and the sidecar `.notes.json` was on disk. With the
recorder connected, the status bar read `7.7 GB free` and Diagnostics
`7.7 GB free of 7.7 GB` (battery 69 %, live). `flutter analyze` clean; 31 tests pass.

---

## 16. Follow-up fixes: endpoint fields, catalog downloads, summary shape (2026-11-11)

1. **External endpoints appear with the half that needs them.** Previously Base URL + API key
   were rendered once *after* the whole Summary block, so switching only Speech to External
   showed a Speech model field with no URL or key. `_endpoints()` now renders inside
   `_externalSpeech()` (when speech is external) or `_externalSummary()` (when only summary
   is external); when both are external, Summary points back to the fields under Speech.
2. **The Summary picker offers the whole catalog, not just installed files.** `/health` already
   carried `summary_catalog`; the app now renders every entry — installed models selectable,
   missing ones as `name · size GB` with a download icon. Tapping starts a download **on the
   serving machine**:
   - `notra/ai.py: download_model()` streams to `<file>.part` and renames on completion.
   - `POST /models/download {"name": …}` starts it on a daemon thread; `GET
     /models/download?name=…` returns `{state, received, total}`; `GET /models` lists the
     catalog + states. `scripts/fetch_model.py` uses the same function.
   - The app polls every 2 s, shows a progress bar/percentage, re-reads `/health`, and selects
     the model when it lands. While a download runs, other downloads and Test are disabled.
3. **Summary format is normalised.** `normalise_sections()` in `notra/ai.py` (and
   `normaliseSections()` in `app/lib/ai/notes.dart`) map model output onto the template's
   headings and order, accept aliases (`summary` → Overview, `Actions` → Decisions & actions,
   `Takeaways` → Key points…), flatten strings/lists, strip `-`/`•`/numbering, and append
   unknown non-empty sections at the end. Prompts now include the exact JSON shape. GGUF/LLM
   output with no usable section returns `None`, so the extractive template takes over instead
   of showing an empty/odd sheet. Old sidecars are re-ordered on read.
4. **Panel loading state and live header.** The first `/health` call on opening Setup can race
   the USB bridge; the panel now retries once, and says "Checking the local service…" instead
   of the misleading "No GGUF yet" until a response lands. `_healthOk == false` explains that
   summaries will be extractive until the service answers. The Transcription disclosure now
   listens to `AiSettings` as well as `Session` (`Listenable.merge`), so
   `external speech · local summary` updates immediately rather than waiting for the next
   device event.

Verified on the tablet: Speech → External showed Base URL + API key directly beneath the
Speech model; Summary → On this machine listed `qwen2.5-3b · 1.9 GB`, `llama-3.2-3b · 2.0 GB`
and `qwen2.5-7b · 4.7 GB`; tapping 3B downloaded it in ~15 s and the app selected it after
`GET /health`. With 3B, the same 48 s take produced all three lecture sections in order
(`Overview`, `Key concepts`, `To review`) and clean bullets; `/summarize` was called without
`/transcribe` when switching template. `flutter analyze` clean; 34 tests pass.

---

## 17. Renamed to Geeny, new launcher mark (2026-11-11)

- **Product name is Geeny.** Android `android:label`, `MaterialApp.title`, the in-app wordmark
  (`Geeny.`), the web console (`<title>` + `<h1>`) and the docs now say Geeny. The device is
  still the Boya Notra Neo, so the `notra/` Python package, `NotraClient`, the BLE scan filters
  and the protocol notes keep that name.
- **Package and application id renamed too.** Dart package `geeny_app`; Android namespace and
  application id `dev.geeny.app`; `MainActivity` moved to
  `android/app/src/main/kotlin/dev/geeny/app/`. Because the id changed, the app installs as a
  new package; the existing `app_flutter` (takes, `.notes.json`, `library.json`,
  `projects.json`) and `shared_prefs/FlutterSharedPreferences.xml` were copied from
  `dev.notra.notra_app` to `dev.geeny.app` with `run-as`, absolute paths in `library.json`
  rewritten to the new package, file mtimes restored, and the old package removed.
- **New icon.** `scripts/make_icon.py` now draws a geometric paper **G** on forest stock with
  one sage recording light, replacing the microphone mark. It regenerates the five legacy
  mipmaps, `mipmap-anydpi-v26` (adaptive + monochrome), the vector foreground,
  `values/colors.xml`, `app/assets/brand/icon.svg` and `web/favicon.svg`.
- **Verified:** `aapt2 dump badging` reports `application-label:'Geeny'` and
  `package: name='dev.geeny.app'`; the launcher/splash shows the G mark and the app drawer
  lists **Geeny**; the home header reads `Geeny.`; after migration the new id shows all 7
  takes, the editable title, the Sampling assignment, the cached notes and the 3B AI settings;
  `flutter analyze` clean; 34 tests pass.

---

## 18. Search/ask, Boya OS import, model housekeeping (2026-11-11, later)

Three requests, all in and verified on the Lenovo tablet.

### 1. AI search and chat across transcriptions/summaries

| Piece | Path | Notes |
|---|---|---|
| `notra/search.py` | new | passage index (BM25), library loader, cited answers |
| `scripts/ai_server.py` | extended | `/index`, `/search`, `/chat` on :8765 |
| `app/lib/ai/ask.dart`, `ui/ask_sheet.dart` | new | Search/Ask sheet from the header magnifier |
| `app/lib/ai/ai_client.dart`, `state/takes.dart` | extended | `indexDocuments`, `indexState`, `search`, `ask`, corpus builder |
| `notra/cli.py` | extended | `python -m notra find "…"` / `ask "…" --library <dir>` |

How it works: the app pushes the text it already has (transcript segments + summary sections +
title/project/date) to the service, which rebuilds an in-memory index of ~700-character
passages (speaker changes split a passage; summary sections are passages of their own). Search
is BM25 with title/project weighting and a phrase bonus; CJK gets character bigrams, so Malay,
English and Chinese all match. Ask takes the six best passages, numbers them and asks the local
GGUF for a short answer with `[n]` citations. Without a GGUF the passages themselves are
returned and labelled *extractive*. Nothing leaves the machine, and no audio is ever indexed.

The index is revision-guarded so a search field does not re-push per keystroke, and
`syncSearchIndex` checks `GET /index` so a restarted service (empty index) is re-filled
automatically.

Verified on the tablet: 1 take / 4 passages indexed; searching "language" returned the summary
sections and the transcript line with its timestamp; Ask with the 3B model answered
`[1] Rekod tak bermakna kita menggunakan transkripsi atau transkripsi.`, cited source `[1]`
highlighted, and tapping it opened the notes sheet on the Transcript pane at `00:00`.

### 2. Import from Boya OS

Boya OS has no import API — recordings live in its cloud. Its APK does have a share/export
surface (see `research/VENDOR_AI.md`): `shareAndroidFile`, "Export Audio" (WAV/MP3/Ogg), "Export
Transcript" as TXT/Markdown/SRT/DOCX/PDF. Geeny now accepts what that app can hand over.

| Piece | Path | Notes |
|---|---|---|
| `MainActivity.kt`, `AndroidManifest.xml` | extended | ACTION_SEND/VIEW filters + `dev.geeny.app/share` channel (copies the content URI into cache), ACTION_OPEN_DOCUMENT picker |
| `app/lib/import/share_in.dart` | new | Dart side of the channel, typed `SharedFile` |
| `app/lib/import/boya_import.dart` | new | TXT / Markdown / SRT / JSON parsers → transcript segments + summary sections |
| `app/lib/state/takes.dart` | extended | `importShared`, `importAudio`, `importNote`, notes-only takes, `notice` |
| `app/lib/ui/takes_section.dart` | extended | Import sheet, import notice, disabled Play on audio-less takes |

- Sharing audio creates a normal, playable take (`boya-<name>-<stamp>.ogg`); `opus`/`oga` are
  stored as `.ogg` so the local pipeline reads them. Ogg/WAV transcribe; MP3/M4A play but the
  local service cannot decode them — the import notice says so instead of failing later.
- A transcript export is attached to the take with the same stem (or the same title), otherwise
  it becomes a **transcript-only take**: a `.notes.json` with no audio beside it. It is listed,
  searchable, readable, exportable and deletable; Play is disabled and the row says
  "transcript only".
- DOCX/PDF are rejected with a message telling the user to export TXT/Markdown/SRT.

Verified on the tablet: `am start -a SEND -t text/plain --es android.intent.extra.TEXT …`
produced `imported-…ogg.notes.json`, the notice "…as a transcript-only take — the audio stayed
in Boya OS", a row with a disabled Play button, row actions without Play, and a working delete.
Picking a pushed `.ogg` from the system picker (`Import → Choose a file → Downloads`) produced
`boya-Boya lecture 11 Nov-2026-11-11T0908.ogg`, playable, with its duration read correctly.

**Fixed while testing:** `Take.readDuration` took the *maximum* granule across Ogg pages; one
damaged page reported a 48 s take as `175:41`. It now uses the last page's granule (the Ogg
definition) and falls back to the max only when the final granule is zero. Covered by
`app/test/duration_test.dart`.

### 3. Housekeeping — delete downloaded models

| Piece | Path | Notes |
|---|---|---|
| `notra/ai.py` | extended | `model_storage()`, `delete_model()`, whisper HF-cache detection |
| `scripts/ai_server.py` | extended | `GET /models/storage`, `POST /models/delete` (unloads first) |
| `app/lib/ui/models_section.dart` | new | Setup → Models on this machine |
| `scripts/fetch_model.py` | extended | `--storage`, `--delete NAME`, `--delete whisper:small`, `--prune-parts` |

Lists summary GGUFs, whisper snapshots under `~/.cache/huggingface/hub/models--*faster-whisper*`
and interrupted `.part` files, with sizes and a total. Delete is confirmed, unloads the model
before unlinking (Windows keeps a handle), refuses while that model is downloading, and only
matches names that exist on disk — a request cannot name an arbitrary path. Deleting the
selected summary model resets the setting to `auto`; the settings panel refreshes its catalog
via `Takes.modelsRevision`.

Verified on the tablet: 6 models / 3.86 GB listed, deleting a planted 1 MB GGUF reported
"1 MB freed" and the file disappeared; a planted `.part` was removed the same way; a planted
whisper cache directory was deleted through the API (`freed: 300000`) and path traversal was
rejected.

### Also fixed in this round (found by the above)

- **Two services could listen on :8765 and silently split requests** (one gets `/index`, the
  other `/chat`), each loading its own model. `ai_server.py` now probes `/health` first and
  refuses to start a second instance. Kill stale ones with `netstat -ano | grep :8765`.
- **llama.cpp is driven under a lock** (`ai._LLM_LOCK`): concurrent summarize/title/chat calls
  previously raced inside the native library (GGML asserts, process death). Concurrent
  `/chat` now serialises and completes.
- **`/health` no longer blocks**: the torch/diarizer import and the three-port LLM probe are
  warmed in background timers, so a poll is ~3 ms instead of ~2 s (which used to make the app's
  first probe time out).
- `ai_server.py` warms `speakers` after 8 s and reports `index` state in `/health`.

Verified: `flutter analyze` clean, **48 tests** pass (`flutter test`), `python tests/test_search.py`
and `python tests/test_frame.py` pass, `ux_audit` green on the shared web stylesheet. Known
limits: no word-level highlighting inside a search hit; answers are limited to six passages
(larger libraries are summarised by retrieval, not exhaustive); DOCX/PDF exports are not parsed;
a transcript-only take cannot be played.

## 19. AI on the device itself (2026-11-11, later)

The user asked for the speech and summary models to run **on the phone**, not only on a PC.
Speech and summary can now each be routed to one of three backends: **On this device**,
**On this machine** (the service), **External service**. Nothing else changed shape — the
on-device engine returns the same JSON as `scripts/ai_server.py`, so sidecars, search,
titles, the notes sheet and the CLI cannot tell the difference.

### Pieces

| Piece | Path | Notes |
|---|---|---|
| `app/lib/ai/device/device_models.dart` | new | catalog, streaming download with progress + cancel, tar.bz2 unpack, delete, byte counts |
| `app/lib/ai/device/device_asr.dart` | new | sherpa-onnx whisper, isolate entry point |
| `app/lib/ai/device/device_llm.dart` | new | llamadart (llama.cpp) summaries + titles, JSON-schema constrained |
| `app/lib/ai/device/device_ai.dart` | new | routing, model choice, isolate jobs, `probe()` / `health()` |
| `app/lib/ai/device/audio_io.dart` | new | Ogg Opus → 16 kHz mono PCM via `audio_decoder`, WAV parser |
| `app/lib/ai/device/segments.dart` | new | token timings → timestamped segments |
| `app/lib/ai/device/extractive.dart` | new | port of `notra/ai.py:summarize_extractive` |
| `app/lib/ai/ai_settings.dart` | extended | `AiBackend.device`, `deviceSpeech`, `deviceSummary`, labels |
| `app/lib/ai/ai_client.dart` | extended | routing per half, `deviceHealth()`, injectable engine for tests |
| `app/lib/ui/ai_settings_section.dart` | extended | third chip per half, model pickers, downloads, delete, storage |
| `app/lib/ui/models_section.dart` | extended | "On this device" block beside the machine's models |
| `app/test/device_*`, `app/test/ai_routing_test.dart` | new | 84 tests total (`flutter test`) |
| `app/integration_test/device_pipeline_test.dart` | new | the real thing, on hardware |

Dependencies: `sherpa_onnx` 2.0.1, `llamadart` 0.19.4, `audio_decoder` 0.8.1, `archive` 4.6.0.

### Verified on the Lenovo tablet (TB336FU, Android 16, 8 GB)

`flutter test integration_test/device_pipeline_test.dart` — media served from the PC over
`adb reverse tcp:8899` so the test does not depend on the tablet's network.

```
models on device: 595 MB              (whisper tiny + qwen2.5-0.5b, downloaded in-app)
transcription: 8919 ms                (17 s Ogg Opus, mono 16 kHz)
transcript: we reviewed the sampling plan for the northern plot. the field data looks
            consistent with last quarter. we need to finish the sampling plan before
            friday. marta will send the revised schedule to the lab. the budget review
            is scheduled for next month.
summary (on device · llama.cpp · 0.5B): 20326 ms
sections: {Overview: [...], Decisions & actions: [...], Key points: [...]}
title: Northern Plot Sampling Plan Review
```

Word-for-word correct, no service, no network. The extractive path and the `probe()` model
check were asserted in the same test.

### Gotchas worth not rediscovering

- **A closure created in an instance method captures `this`.** `Isolate.run(() => …)` inside
  `DeviceModels.download` / `DeviceAi.transcribe` failed with "Illegal argument in isolate
  message: object is unsendable" because the closure carried the `ChangeNotifier`/`_active`
  map. Every isolate entry point is now a **static** helper taking only strings/ints; the
  closure is built there.
- **sherpa whisper bundles prefix their files**: the real tiny archive holds
  `tiny-encoder.int8.onnx`, not `encoder.int8.onnx`. Unpacking matches a name that *ends with*
  the canonical one and writes it under the canonical name, so both layouts install. The
  archive also carries full-precision models — only the three needed files are written, or
  `small` would leave 1.4 GB behind.
- **Ogg Opus decodes with the platform** (`audio_decoder` → MediaCodec), so no FFmpeg and
  no bundled codec. Decoding to a WAV file and passing only the path into the isolate keeps
  memory small and the interface trivial.
- **A 0.5B GGUF invents headings and returns empty arrays** without constrained decoding.
  `device_llm.dart` now passes a `responseFormat` JSON schema built from the template (plus
  "every key needs at least one bullet" in the prompt). That fixed
  `Overview: []` — at roughly 2× the generation time (8 s → 20 s on a 17 s take). Worth it.
- **`AiBackend` is persisted as a string**; `'device'` was added to `_encode`/`_parseBackend`.
  Older builds had one mode for both halves, so the legacy `ai.mode` value still seeds both.
- **`pubspec.yaml` asked for `sdk: ^3.13.7`** while the installed Flutter is 3.47.7 (Dart
  3.13.5) — `flutter pub get` refused to resolve. Relaxed to `^3.13.5`. If the toolchain is
  upgraded past 3.13.7 this can go back.
- **`android.permission.INTERNET`** was only in the debug manifest: on-device downloads would
  have failed in a release build. Added to `AndroidManifest.xml`.
- **APK size**: llama.cpp native assets bring `libLiteRtLm.so`, `libggml-vulkan.so`,
  `libVkLayer_khronos_validation.so` and `libwebgpu_dawn.so` with them (~40 MB per ABI, unused
  here). Debug (3 ABIs) is ~450 MB; `flutter build apk --release --split-per-abi` is the
  honest way to install. Excluding the unused libs with `packagingOptions` is untested — do
  not do it without checking llama.cpp still loads.
- **`scripts/make_test_clip.py`** makes a spoken Ogg Opus at 16 kHz mono (Windows SAPI +
  libsndfile), which is what the recorder produces. That is how the integration test has
  audio without the hardware.

### Deliberate limits

- Search/Ask ran on the service and needed it to be up (fixed in §22 — the index is in the app
  now), so a device-only setup could transcribe and summarise offline but not search.
- The on-device catalog stops at whisper `small` and a 1.5B GGUF. 3B/7B and `medium` stay on
  the machine: RAM, heat and patience.
- llama.cpp runs **CPU only** (`gpuLayers: 0`, `ComputeDevice.cpu`) on purpose — a broken
  Vulkan driver should not turn a summary into a crash. Revisit if GPU offload is wanted.
- Defaults are unchanged (both halves `local`), so an existing PC setup keeps working. The
  device path is opt-in, per half, in Setup.

### Next, if it is ever wanted

1. ~~On-device Search/Ask~~ — done in §22.
2. Trim the unused llama.cpp runtimes from the APK, then measure a release build per ABI.
3. Optional Vulkan offload for the summary model, behind a setting that falls back to CPU.
4. Speaker labels on device: sherpa-onnx also ships diarization models; the same download
   machinery would carry them.

## 20. Player bar, titles, lengths, audio export (2026-11-11, later)

Five things a configured library on the tablet exposed. Nothing was deleted: the three
recordings in `app_flutter/` were used as the test material and are still there.

### 1. The seek slider is back (it was never in this repo)

`Takes` has always tracked `position`/`duration` and exposed `seek`, but **no widget ever
showed them** — `git log -S"Slider"` on `lib/` is empty, so playback was play/pause only.
`app/lib/ui/player_bar.dart` now holds `SeekSlider` (the scrubber: a local `_dragging` value,
seeking only on release), `PlayerBar` (the notes sheet's compact bar) and `formatDuration`.

**The scrubber lives inside the row of the recording that is playing**, not in a bar above the
list. The first attempt put a `PlayerBar` at the top of the section, and that was wrong twice
over: it read as *the top take* being in playback, and — because the active row was computed
from a `playingPath` prop — the list never actually highlighted what was playing. `HomePage`
rebuilds on `Session`, `TakesSection` on `Takes`, and `Session` does not forward the library's
notifications, so the prop was stale from the first play. The section now reads
`takes.current` itself.

- the playing row tints, grows a slider with `position / length` and a stop (✕) under its
  title, and its play button becomes pause; every other row stays one line high;
- the notes sheet keeps the compact `PlayerBar` with `onlyFor: take`, so a scrubber is never
  offered for a different recording than the transcript on screen.

### 2. Every recording read three times too long

`Take.readDuration` divided the Ogg granule by 16 (kHz). Opus granule positions are always
**48 kHz samples** whatever the stream's own rate is (RFC 7845 §4), so a 16 kHz mono take was
reported 3× too long: the 1 h 17 m take showed `233:33`, and the short ones `00:18`/`00:16`
instead of `00:06`/`00:05`. Now `/48`, with a test pinned to the recorder's real layout
(`app/test/duration_test.dart`). This is the number beside every take, so it was worth
chasing: it also made the slider's maximum look absurd.

### 3. Titles: `"null"` was being stored as a title

`library.json` held `"...T1300.ogg": "null"`, and the row read “null”. Chat models answer
`null`, `Untitled`, a quoted sentence, a fenced block or a JSON object often enough that the
reply cannot be trusted as a title. `cleanTitle()` in `app/lib/ai/notes.dart` now decides, and
everything that turns a model reply into a title goes through it: the external branch, the
machine service branch, the on-device GGUF branch and its lead-in fallback.

- rejects `null`/`none`/`n/a`/`untitled`/`unknown`/`…`, refusals (“As an AI…”, “I cannot…”),
  JSON, and anything longer than 12 words (prose, not a name);
- strips fences, quotes, backticks, emphasis, list markers, and a trailing full stop;
- trims to 80 characters with an ellipsis;
- `Takes.titleFor` applies it again on read, so a junk title saved by an older build reads as
  *untitled* instead of as text; `_loadIndex` drops those entries on load;
- a take that has a transcript but no title now asks for one when its notes are opened —
  once per take per session (`_titleAttempted`), so a model that answers with nothing cannot
  turn every glance at the notes into another billed request;
- `generateNotes` asks for the title after *any* run (summary-only included), not only after
  transcription.

Verified on the tablet: the `"null"` take fell back to its date; opening it once produced
**“Prueba de funcionamiento”**, which the row and the notes header then showed.

### 4. Save / share the recording

`app/lib/ui/export_audio.dart`, wired to a `Save or share audio` row action and a `Save audio`
button in the notes sheet:

- copies the take to the cache under its **title** (`Prueba de funcionamiento.ogg`) and hands
  it to the system share sheet — *Files by Google*, Drive, Bluetooth, another app. That is the
  download path on Android and needs no storage permission;
- `safeFileName` strips path separators, `..`, control characters and anything that is not a
  letter/digit/space/dot/dash/underscore (Unicode-aware, so Malay and Chinese titles keep their
  letters); untitled takes use `11 Nov 13.00` — the colon becomes a dot, since `:` is illegal
  on some file systems;
- the library copy is never moved or renamed, so an export cannot lose a recording.

Verified on the tablet: the share sheet opened with `Prueba de funcionamiento.ogg` listed and
Files/Drive among the targets.

### 5. An imported MP3 never reached the list

Sharing or picking an MP3 from Boya OS said “Imported … as boya-….mp3” and then the take
was nowhere: `Takes.refresh` built the library from `f.path.endsWith('.ogg')`, so the copy
landed in the documents directory and was filtered straight back out. Nothing was wrong with
the import itself.

- the formats are one set now, `Take.audioExtensions` (`ogg`, `oga`, `opus`, `wav`, `mp3`,
  `m4a`, `aac`, `flac`, `amr`, matching what the share sheet and picker accept) and
  `Take.isAudioPath` is what `refresh` asks;
- length no longer assumes Ogg: `app/lib/state/audio_duration.dart` reads Ogg granule positions,
  WAV `fmt `/`data` byte rates, FLAC STREAMINFO, and MP3 frames (Xing/Info frame count,
  otherwise a frame walk, so VBR is right and ID3v1/v2 tags are skipped). M4A/AAC/AMR have no
  header read here and still show `--:--` instead of a guess;
- tests in `app/test/duration_test.dart` build one MP3 (with and without ID3v2), one WAV and one
  FLAC and pin their lengths, plus the extension set `refresh` uses.

The same import path had a second bug: re-importing a recording that was already there made a
second copy. `importAudio` looked for `_stem(take.name) == base`, but every stored name is
`boya-<name>-<stamp>.<ext>`, so the comparison never matched — the “already in the library”
line was unreachable. `Take.findByContent` now decides: size from the index first, then the
bytes of only the takes of that size, so the answer does not depend on a name a rename or a
re-export can change, and a same-size different recording is still imported. The notice now
names the existing take: *“This recording is already in the library as …”*. Tests in
`app/test/library_test.dart` cover the renamed duplicate, the same-size different file, a
transcript-only take (never a duplicate) and a share that is gone.

**State:** `flutter analyze` clean, **105 tests** pass. The library now lists whatever the import
accepts, so an MP3 shared from Boya OS appears (and plays) like any pulled take, and importing
it a second time says so instead of copying it again. `HANDOFF.md` §19 still describes the AI
routing; this round changed no pipeline behaviour, only what the UI shows, what it does with a
model's answer, which files it counts as takes, and what it does with one it has seen before.

## 21. Summary type chosen before the first transcription (2026-11-11, later)

Opening a take with no transcript used to transcribe **and** summarise straight away with the
default `meeting` template. The template only shapes the summary, not the transcript, but the
first run is the expensive one (whisper on this tablet), so a lecture was transcribed twice —
once as a meeting, then again when the right chip was tapped.

`app/lib/ui/notes_sheet.dart` now holds the first run until a type is picked:

- if `notesAction()` says `transcribeAndSummarize` and the take has audio, the sheet opens on a
  **Summarise this take as** block with full-size `meeting` / `lecture` / `notes` chips instead
  of starting work in `initState`;
- tapping one sets the template and starts the run (`_start`), so a single transcription pass
  yields the summary that was asked for;
- the choice is remembered: `AiSettings.summaryTemplate` (`ai.summaryTemplate` in preferences)
  takes the last picked type, and the notes sheet opens a new take on it instead of `meeting`.
  A take that already has notes always keeps its own template, so an old lecture is not
  relabelled after a meeting is recorded. Unknown or retired values fall back to `meeting`
  rather than producing an empty summary; switching the type on an existing take remembers it
  too;
- **Redo** is hidden while the choice is pending (it would have forced a `meeting` run);
- everything else is unchanged: a take that already has a transcript re-summarises in the
  background for the selected template, switching a template later re-runs only the summary,
  and a take with no audio (transcript/summary imported from Boya OS) is never touched.

`flutter analyze` clean, **118 tests** pass (the remembered type is pinned in
`app/test/ai_routing_test.dart`). No pipeline code changed — only when the first run is
allowed to start and which template it opens with.

---

## 22. Search and Ask stopped needing the service (2026-11-11, last)

With both AI halves set to **On this device**, the app transcribed and summarised with no
service — and search still failed, because the index lived in `scripts/ai_server.py`. The
sheet showed *“The local AI service is not answering. Search runs there.”* and no hits. That
was the one feature the on-device work had left behind (§19 limits, next-step 1).

The index moved into the app:

| Piece | Path | Notes |
|---|---|---|
| `app/lib/ai/search_index.dart` | new | BM25 port of `notra/search.py`: tokenize (unicode words + CJK bigrams), question stopwords, summary/transcript passages split on speaker change and 700 chars/8 segments, title weighted twice, phrase bonus, summary-section bonus, 280-char snippet |
| `app/lib/state/takes.dart` | changed | `final SearchIndex _index` built from `searchDocuments()` in `syncSearchIndex()`; `searchNotes` is now synchronous work; `askNotes` retrieves locally then asks a model |
| `app/lib/ai/ai_client.dart` | changed | new `answer(question, hits)`: on-device GGUF, or a connected service (external API / the machine's `/chat`), else the passages; `search`/`indexState` removed (the endpoints stay for curl and the CLI) |
| `app/lib/ai/device/device_llm.dart` | changed | `answerWithGguf` — the same excerpts prompt the service uses |
| `app/lib/ai/device/device_ai.dart` | changed | `answer()` runs it in an isolate, returns `(text, engine)` or null |
| `app/lib/ai/ask.dart` | changed | `AskHit.excerpt(n)` — one excerpt line, built in one place so phone and service hand a model the same text |
| `app/lib/ui/ask_sheet.dart` | changed | says *searched on this device*; the service-down wording and the `indexing` state are gone |
| `notra/search.py` | changed | the extractive answer now marks `cited` on its sources as well as in the list |

Design decisions worth keeping:

- **Search is not a model feature.** Retrieval is BM25 in Dart on text the app already has, so
  it works with no service, no network, no GGUF, and no download. A library of a few hundred
  passages rebuilds in about a millisecond.
- **Ask degrades honestly, and picks an answerer that exists.** The prose comes from, in
  order: the on-device GGUF (the device summary half, or any installed one when the machine
  cannot answer); the external API (when that half is External — an unreachable host falls
  through to the device model, a rejected key is still raised); the machine's `/chat` (when
  that half is On this machine **and** `GET /health` answers within 3 s). With none of those,
  the top three passages are the answer and the engine says `extractive`. A model that throws
  does not take the passages with it.
- **The machine is probed, not assumed.** `/chat` used to be called blind; with no PC on the
  LAN that meant waiting out a TCP connect timeout (up to the 4-minute request timeout) before
  anything appeared. A 3 s `/health` probe now decides, so the answer comes from the phone
  (or from the passages) within a second instead.
- **The machine's copy is still pushed** (fire-and-forget, after a rebuild) so `POST /chat` and
  `python -m notra find` keep answering from the same corpus. A failure there is silent now:
  it is no longer on the path of a search. `askNotes` awaits that push only when the summary
  half is the machine, so a first question cannot race an empty remote index.
- **`_notesRevision` now also moves on project changes**, since the project is indexed.
- **A summary without a transcript is indexed.** `searchDocuments` used to require
  `note.hasTranscript`, so a summary-only import (Boya OS “Export summary”) was listed but
  unfindable. It now indexes whichever half the take has.

Verified: `flutter analyze` clean; **142 tests** pass (`flutter test`), including the new
`app/test/search_index_test.dart` (19 cases: tokenising, CJK, stopwords, ranking, timestamps,
phrasing, speaker split, summary-only take, snippet cut, extractive citations) and five
`AiClient.answer` routing cases in `app/test/ai_routing_test.dart`: the device answers with
`[1]` and the source row is marked; a machine with nothing to say hands over to the device; an
unreachable external host (`*.invalid`) falls back to the device; an external **401** is raised
rather than hidden (real loopback `HttpServer`); a silent model returns null so the passages
stand in.
`python tests/test_search.py` passes with a new check that `cited` flags and the `cited` list
agree. Not re-run on the tablet this round — the integration test still covers transcription
and summaries; search needs no hardware.

---

## 23. Recording languages declared before transcription (2026-11-11, last)

Whisper guessed the language of every take. On a short or noisy opening, or a meeting that
switches between two languages, that guess is the part that gets the transcript wrong — and
nothing in the app let a person say what they were actually speaking. The first-run panel
(§21) now also asks, as a multi-select, and the answer is kept.

| Piece | Path | Notes |
|---|---|---|
| `app/lib/ai/languages.dart` | new | whisper's 100 codes → names; `normalise` (`EN-gb` → `en`), `sanitise` (dedupe, drop unknown, keep order), `forceFor`, `covers`, `describe`/`label` |
| `app/lib/ui/language_picker.dart` | new | selected languages as removable chips + **Add language** / **Auto · detect**; one sheet with a search field and every language, multi-select |
| `app/lib/ai/ai_settings.dart` | extended | `speechLanguages` (`ai.speechLanguages` in preferences, `getStringList`), sanitised on load, `speechLanguagesLabel` |
| `app/lib/ui/notes_sheet.dart` | extended | **Languages in this recording** in the pre-transcription block; the transcript footer and exported markdown show the name (`German`), not the code |
| `app/lib/ui/ai_settings_section.dart` | extended | the same picker under Setup → Speech, for any take |
| `app/lib/ai/ai_client.dart` | extended | `transcribe(..., languages:)`: device passes them, local sends `?languages=de,en`, external sends `language=` and retries once when the guess lands outside the list |
| `app/lib/ai/device/device_asr.dart` | extended | one whisper pass per forced language; the result's `lang` is used, and a forced language fills in an empty `lang` |
| `app/lib/ai/device/device_ai.dart` | extended | the list crosses into the transcribe isolate |
| `app/lib/state/takes.dart` | extended | `generateNotes` passes the remembered list |
| `scripts/ai_server.py` | extended | `/transcribe` takes `languages=en,de` (and repeated `language=`), same detect-then-fallback rule, `_base_language` normalises |
| `app/test/languages_test.dart` | new | normalise/sanitise/force/covers/describe, persistence across a load, retired codes ignored |
| `app/test/ai_routing_test.dart` | extended | the declared list reaches the device half, sanitised, and nothing declared stays `[]` |

Semantics, chosen to keep a second pass rare:

- **One language is forced.** A known language is one whisper does not have to spend a guess
  on, and the take's `language` falls back to it when sherpa returns an empty `lang`.
- **Several are not forced.** A language is a property of the whisper model config, not the
  stream, so each forced language is a recogniser reload — the expensive kind. Instead the
  first pass detects across the take (a meeting really can switch mid-way) and the first
  language the person picked is forced **only** when the detection lands outside the list.
- **Order is the priority.** `setSpeechLanguages` keeps choice order, so "fallback" means the
  first chip, not an arbitrary set member. Unknown codes (`klingon`) are dropped rather than
  put on the wire; `en-GB` folds to `en`.
- **Asked once, remembered.** The picker lives in the same first-run panel as the summary
  type, and in Setup → Speech; `ai.speechLanguages` restores it on launch. **Redo**
  re-transcribes with whatever is selected at that moment, so a wrong guess is one tap away.

`flutter analyze` clean; **151 tests** pass, including the new `app/test/languages_test.dart`
(8 cases). Built `--release --split-per-abi` and installed on the TB336FU tablet
(`adb -s HA2K8842 install -r app-arm64-v8a-release.apk`, package `dev.geeny.app` 1.0.0). The
Python service change is not exercised by the Flutter tests; `scripts/ai_server.py` compiles
and the endpoint ignores unknown parameters, so an older service still transcribes.
