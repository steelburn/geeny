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
5. **Launcher icon.** `scripts/make_icon.py` draws the mark (forest stock, paper microphone,
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
