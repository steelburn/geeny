# geeny_app

**Geeny** — Flutter client for the Boya Notra Neo recorder. Scan, connect, record, pull takes,
play them, and transcribe/summarise — on the phone itself, on a machine next to you, or
through an OpenAI-compatible service, chosen per half.

The project overview, protocol notes and AI setup live in the repository root:

- [`../README.md`](../README.md) — what works, setup, transcription and summaries
- [`../HANDOFF.md`](../HANDOFF.md) — state of play, hardware gotchas, session log
- [`../DESIGN.md`](../DESIGN.md) — the shared design system

## Build and run

```bash
export PATH="/c/Users/USER/flutter/bin:$PATH"
export JAVA_HOME="C:\Users\USER\jdk-17.0.21+9"

flutter pub get
flutter test                     # codec, CRCs, session flow, library, notes, import, device AI
flutter analyze

flutter build apk --debug        # -> build/app/outputs/flutter-apk/app-debug.apk
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

The local AI service is reached at `http://127.0.0.1:8765` by default (works with
`adb reverse tcp:8765 tcp:8765`). Override the address at build time:

```bash
flutter build apk --dart-define=NOTRA_AI_URL=http://192.168.1.20:8765
```

There is deliberately no URL field in the app: it probes the default and the usual
candidates on first use and remembers the one that answers `/health`.

## Search, import, housekeeping

- **Ask** (magnifier in the header) searches every transcript and summary, or answers a
  question with citations. The index and the retrieval are in the app (`lib/ai/search_index.dart`),
  so search works with no service and no network. The prose comes from the on-device model or
  from a connected service (the external API, or the machine's `/chat` when it answers), and
  from the matching passages when neither is there. Audio is never indexed.
- **Import** (Takes header) accepts what Boya OS can share or export: audio (Ogg/WAV play and
  transcribe; MP3/M4A play only) and transcripts/summaries as TXT/Markdown/SRT/JSON. The
  kind suffix on the name (`(Recording)`, `(Transcript)`, `- Summary`) is ignored, so the
  exports of one meeting land on one take whatever order they arrive in. Without a
  recording here they stay a *transcript-only* or *summary-only* take — readable,
  searchable, deleteable, no Play button.
- **Group** (Takes header) is the manual version: enter group mode, pick two or three takes
  of different kinds (a recording, a transcript, a summary), and they become one take. The
  recording is kept as the audio and the notes are merged; picking two of a kind is refused
  because two recordings are two meetings.
- **Setup → Models on this machine** lists every downloaded GGUF/whisper model with its size
  and a confirmed delete, so a machine that tried four whisper sizes can get the space back.
  **On this device** models are listed in the same panel, above the machine's.

## Playback, titles, saving a take

- **Player in the row** (`ui/player_bar.dart`, `ui/takes_section.dart`): the take that is
  playing opens its own scrubber under its title — play/pause, slider, `position / length`,
  stop. Other rows stay compact. The notes sheet shows the same `SeekSlider` in a compact bar
  while its own take is loaded. Dragging seeks on release.
- **Lengths** come from the Ogg granule at 48 kHz (RFC 7845), not the stream's 16 kHz rate.
- **Titles** are model output, so `cleanTitle()` (`ai/notes.dart`) decides whether a reply is
  a title at all: `null`, `Untitled`, quotes, fences, JSON and paragraphs are rejected, and a
  take without one shows its date. A transcript with no title is asked for once per session
  when its notes are opened.
- **Save or share audio** (`ui/export_audio.dart`) copies the take to the cache under its
  title and opens the system sheet; the library file is untouched.

## On-device AI

Setup → **Speech**/**Summary** → **On this device** runs whisper (sherpa-onnx) and a GGUF
(llama.cpp) inside the app. No service, no network, nothing uploaded; taps on a missing model
download it (116 MB–1.9 GB) into the app's support directory, with progress, cancel and
delete. `extractive` summaries need no model at all.

- `lib/ai/device/` — model store and downloads, Ogg Opus → 16 kHz PCM, whisper, llama.cpp,
timestamped segments, the extractive fallback, and the routing facade.
- Each job runs in a short-lived isolate; the closures live in **static** helpers, because a
  closure made inside an instance method captures `this` and cannot be sent.
- `flutter test integration_test/device_pipeline_test.dart -d <device>` proves the whole path
  on hardware (see the root `README.md` for the media-server setup it expects).

## Layout

```
lib/ai/          AiSettings (independent speech/summary routing), client, notes, ask
                 models, the in-app search index (BM25)
lib/ai/device/   on-device whisper + llama.cpp, model store and downloads
lib/ble/         flutter_blue_plus link + protocol operations
lib/import/      share-sheet bridge + Boya OS export parsers (TXT/MD/SRT/JSON)
lib/protocol/    frame codec, CRC16/CRC32, assembler
lib/state/       Session (device) and Takes (library, playback, notes, import)
lib/theme/       tokens and theme (mirrors ../DESIGN.md)
lib/ui/          home page, takes ledger, notes sheet, ask sheet, setup panel, housekeeping
```

Launcher icons are generated by `../scripts/make_icon.py`; edit the script, not the PNGs.
