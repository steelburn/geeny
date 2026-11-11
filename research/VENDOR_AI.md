# How Boya OS does transcription and summaries

Recovered from the shipped APK (`com.wanmei.boyanotra`, Flutter, `libapp.so`) — strings,
endpoint paths and model names. Same method as the BLE protocol: no official SDK exists,
so this is all from unpacking and watching the app.

## Short version

Transcription and summarisation are **entirely cloud-side**. The app uploads the audio,
the vendor's servers do ASR (Azure Speech for the realtime path) plus an LLM with
templates, and results come back as transcript + structured summary. It is metered in
**minutes** against the account's plan (the app showed `used 268.42/600.00 minutes` for
"Starter"), and the audio is stored in the vendor cloud (S3 presigned URLs).

There is nothing on-device to reverse engineer, and no model ships in the APK. That is why
this project cannot "clone" the vendor AI the way it cloned the BLE protocol — the value is
a service, not a protocol.

## Endpoints (base `https://ai.boyaos.com/prod-api`)

```
POST /api/asr/transcribeAndSummarize      one-shot: audio in, transcript + summary out
POST /api/asr/pre/transcribe              pre-transcribe
POST /api/asr/fast/transcribe             fast path
POST /api/asr/again/transcribe            retry a failed file
GET  /api/asr/model/list                  available ASR models / languages
GET  /api/asr/transcriptions/summaries/result   fetch stored results
POST /api/asr/save/transcribe             persist a transcript
POST /api/asr/save/summary                persist a summary
POST /api/asr/summary/translate           translate a summary
POST /api/asr/share/create                share link
POST /api/asr/feedback                    quality feedback
POST /api/asr/recordings/images/upload    images attached to a recording
GET  /api/asr/azure/realtime/token        Azure Speech token
POST /api/asr/azure/realtime/end          end the realtime session
WS   /api/asr/meeting/stream              realtime meeting transcription
WS   /api/asr/all/meeting/stream          realtime, all-session variant
POST /api/asr/realtime/heart              keep-alive while streaming
GET  /api/cloud/sts/token                 S3 credentials for uploads
POST /api/cloud/file/save | list | remove | move | rename
POST /api/operations/selectCategoryWithTemplates   summary template catalogue
```

Signals in the binary: `TranscriptionParameters`, `FileSummaryResultModel`,
`SummaryTemplateModel`, `TemplatePreviewSheet`, `Export Transcript`, `summaryExportShared`,
and strings like "Insufficient transcription time", "Please turn on transcription first",
"againTranscriptionFailed".

## Realtime path

`/api/asr/azure/realtime/token` hands out an **Azure Speech** token; the app then streams
audio and ends with `/api/asr/azure/realtime/end`. So realtime transcription is Azure,
proxied through the vendor backend (probably for billing and to hide the key).

## Summaries

Server-side, template-driven. Advertised as "40+ professional templates" / "60+ professional
templates", with these visible in the binary:

```
templateProjectMeeting          project meeting minutes
templateUniversityLectureMinutes university lecture notes
templateClassroomInteraction    classroom interaction
PROFESSIONAL_TEMPLATES, CUSTOM_TEMPLATES, INFINITE_PROFESSIONAL_TEMPLATES
My Templates / No templates / Customize your own templates
```

Output formats: DOCX (Word), Markdown/markmap mind maps, share links, translated summaries.
The prompt text itself lives on the server, not in the APK.

## What this means for `notra`

The vendor's AI is not reproducible from the device side: no key, no local model, no
protocol — just an account and a quota. Two viable directions for this project:

1. **On-device, offline** (matches the project's "no cloud, no account" stance):
   whisper.cpp for ASR and a small local LLM for summaries, both shipped/loaded on the
   tablet. Works offline, costs nothing per minute, slower and with weaker summaries.
2. **Local service on the LAN**: the app POSTs the `.ogg` to a machine running
   faster-whisper + an LLM (Ollama), and shows the result. Much better quality, no account,
   but needs the PC awake.

Either way the app keeps its own transcript/summary model: transcript with segment
timestamps (so a row can seek the player), and a summary rendered from a template.

## What we built instead (local counterpart)

Chosen path: keep the audio and the compute on hardware we own.

```
pull (BLE) -> Ogg Opus -> faster-whisper on the PC -> transcript with segment times
                                              -> template summary (extractive, or a local
                                                 LLM via LM Studio / Ollama if running)
```

Implemented in `notra/ai.py`, exposed as `scripts/ai_server.py` (HTTP :8765) for the app and
as `python -m notra transcribe|summary` for the CLI. The app shows a notes sheet per take:
template chips (meeting / lecture / notes), summary bullets, and a timestamped transcript
that seeks the player. No account and nothing leaves the machine.

Deliberately *not* cloned: the vendor's Azure realtime streaming and its template catalogue.
Realtime streaming would need a streaming ASR; our takes are short and pulled after the fact,
so batch transcription is the better fit.

## Follow-ups worth doing

- Capture the HTTPS traffic of one cloud transcription (mitm) to see the request shape:
  multipart vs presigned upload, whether audio is Opus or re-encoded, language hints.
- `/api/asr/model/list` may reveal which vendor/model is used server-side; not needed for
  our own pipeline, but it documents the quality bar.

## What the app can hand over (import surface)

Extracted from `libapp.so` alongside the endpoints — this is what makes an import possible
at all, because there is no API to read a recording back out of the vendor cloud:

```
shareAndroidFile filePath=          # Android share sheet, any file
shareAndroidUrlString urlString=    # and links
Export Audio                        # checkAndExportWAV, checkAndExportMP3
Export Transcript / Export Summary  # exportTxt, exportMarkdown, exportPdf, exportDocx
SrtExportUtils / shareSrt           # SRT with timestamps
Export as PDF, TXT, Markdown, and more
```

So the practical interoperability path is file-based, not network-based:

- **Audio**: share an exported recording (Ogg is best — that is the device format and the
  local service decodes it; WAV also works; MP3/M4A need an external speech service).
- **Text**: share an exported transcript. TXT, Markdown and SRT carry timestamps that become
  seekable transcript rows. DOCX and PDF are not parsed.

Geeny registers for `ACTION_SEND`/`ACTION_VIEW` on audio, TXT/Markdown/SRT and JSON, plus an
in-app system picker, so both the Share button and the Export menu land somewhere useful.
The vendor's own cloud stays untouched: no account, no key, no scraping — which is also why
importing a recording that never left the phone is not possible.

Checklist if a future firmware changes the export set: re-run the string dump, look for
`exportTxt`/`exportMarkdown`/`checkAndExport*`, and update `app/lib/import/boya_import.dart`
(the parsers are pure functions with unit tests in `app/test/import_test.dart`).
