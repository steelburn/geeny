"""Tiny local AI service for the Geeny app (transcript + summary).

The vendor does this in the cloud; this keeps it on your own machine. The app posts
the pulled `.ogg` here, gets a transcript back, then asks for a summary.

    uv run --with faster-whisper --with soundfile --with numpy python scripts/ai_server.py

Endpoints (port 8765):
    GET  /health                 {"ok": true, "model": "...", "llm": bool, ...}
    GET  /models                 summary-model catalog + download states
    POST /models/download        body = {"name": "..."} -> background download
    GET  /models/download?name=  {state, received, total}
    POST /transcribe             body = raw .ogg/.opus bytes -> transcript JSON
    POST /summarize              body = {"transcript": {...}, "template": "meeting"}
    POST /title                  body = {"transcript": {...}} -> short title

The tablet reaches it either over Wi-Fi or, for development, through
`adb reverse tcp:8765 tcp:8765` (then the app uses http://127.0.0.1:8765).
"""
from __future__ import annotations

import json
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from notra import ai  # noqa: E402

PORT = 8765
MODELS = ("tiny", "base", "small", "medium")
DEFAULT_MODEL = "base"
_lock = threading.Lock()
_models: dict[str, object] = {}   # whisper model size -> loaded WhisperModel
_downloads: dict[str, dict] = {}  # catalog model name -> download state
_downloads_lock = threading.Lock()


def _speakers_available() -> bool:
    try:
        from notra import diarize
        return diarize.available()
    except Exception:
        return False


def _get_model(size: str):
    size = size if size in MODELS else DEFAULT_MODEL
    model = _models.get(size)
    if model is None:
        from faster_whisper import WhisperModel
        model = WhisperModel(size, device="cpu", compute_type="int8")
        _models[size] = model
    return model


def _download_worker(name: str) -> None:
    def progress(done: int, total: int) -> None:
        with _downloads_lock:
            _downloads[name] = {
                "state": "downloading",
                "received": done,
                "total": total,
            }

    try:
        target = ai.download_model(name, progress=progress)
        size = target.stat().st_size
        with _downloads_lock:
            _downloads[name] = {
                "state": "done",
                "received": size,
                "total": size,
                "path": str(target),
            }
    except Exception as exc:  # noqa: BLE001 - reported to the app
        with _downloads_lock:
            _downloads[name] = {
                "state": "error",
                "error": f"{type(exc).__name__}: {exc}",
            }


def _download_state(name: str) -> dict:
    with _downloads_lock:
        state = dict(_downloads.get(name, {}))
    if state:
        return state
    entry = ai.MODEL_CATALOG.get(name)
    if entry and (ai.MODELS_DIR / str(entry["file"])).is_file():
        return {"state": "done"}
    return {"state": "idle"}


def _transcribe_bytes(blob: bytes, model_size: str = DEFAULT_MODEL) -> ai.Transcript:
    with tempfile.NamedTemporaryFile(suffix=".ogg", delete=False) as fh:
        fh.write(blob)
        tmp = Path(fh.name)
    try:
        transcriber = _get_model(model_size)
        import numpy as np
        import soundfile as sf
        from notra.ai import Segment

        audio, rate = sf.read(str(tmp), dtype="float32", always_2d=False)
        if rate != 16000:
            raise RuntimeError(f"expected 16 kHz, got {rate}")
        with _lock:
            segments, info = transcriber.transcribe(
                np.ascontiguousarray(audio), vad_filter=True, beam_size=1
            )
            segs = list(segments)
        return ai.Transcript(
            source="upload",
            language=info.language,
            language_probability=float(info.language_probability),
            duration=float(len(audio) / rate),
            segments=[Segment(float(s.start), float(s.end), s.text.strip()) for s in segs],
        )
    finally:
        tmp.unlink(missing_ok=True)


class Handler(BaseHTTPRequestHandler):
    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # quieter logs
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    def do_GET(self):
        if self.path.startswith("/models/download"):
            from urllib.parse import urlparse, parse_qs

            qs = parse_qs(urlparse(self.path).query)
            name = (qs.get("name") or [""])[0]
            if name not in ai.MODEL_CATALOG:
                self._json(400, {"error": f"unknown model {name!r}"})
                return
            self._json(200, _download_state(name))
        elif self.path.startswith("/models"):
            with _downloads_lock:
                downloads = {k: dict(v) for k, v in _downloads.items()}
            self._json(200, {"models": ai.summary_catalog(), "downloads": downloads})
        elif self.path.startswith("/health"):
            self._json(200, {
                "ok": True,
                "models": list(MODELS),
                "loaded": sorted(_models),
                "default_model": DEFAULT_MODEL,
                "llm": ai._llm_available() or None,
                "local_llm": (ai.llm_model_path().name if ai.llm_model_path() else None),
                "local_llms": ai.available_llms(),
                "default_llm": ai.DEFAULT_LLM_NAME,
                "summary_catalog": ai.summary_catalog(),
                "speakers": _speakers_available(),
            })
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        blob = self.rfile.read(length) if length else b""
        try:
            if self.path == "/models/download":
                req = json.loads(blob or b"{}")
                name = str(req.get("name") or "")
                entry = ai.MODEL_CATALOG.get(name)
                if not entry:
                    self._json(400, {"error": f"unknown model {name!r}"})
                    return
                target = ai.MODELS_DIR / str(entry["file"])
                if target.is_file():
                    self._json(200, _download_state(name))
                    return
                with _downloads_lock:
                    current = dict(_downloads.get(name, {}))
                if current.get("state") != "downloading":
                    with _downloads_lock:
                        _downloads[name] = {
                            "state": "downloading",
                            "received": 0,
                            "total": 0,
                        }
                    threading.Thread(target=_download_worker, args=(name,), daemon=True).start()
                self._json(200, _download_state(name))
            elif self.path.startswith("/transcribe"):
                from urllib.parse import urlparse, parse_qs

                qs = parse_qs(urlparse(self.path).query)
                model_size = (qs.get("model") or [self.headers.get("X-Whisper-Model") or DEFAULT_MODEL])[0]
                transcript = _transcribe_bytes(blob, model_size)
                payload = transcript.to_dict()
                payload["model"] = model_size
                self._json(200, payload)
            elif self.path == "/title":
                req = json.loads(blob or b"{}")
                data = req.get("transcript") or {}
                from notra.ai import Segment, Transcript

                transcript = Transcript(
                    source=data.get("source", "take"),
                    language=data.get("language", ""),
                    duration=float(data.get("duration") or 0),
                    segments=[Segment(**{k: v for k, v in s.items() if k != "speaker"})
                              for s in data.get("segments", [])],
                )
                self._json(200, {
                    "title": ai.make_title(transcript, model_name=req.get("summary_model")),
                })
            elif self.path == "/summarize":
                req = json.loads(blob or b"{}")
                data = req.get("transcript") or {}
                from notra.ai import Segment, Transcript

                transcript = Transcript(
                    source=data.get("source", "take"),
                    language=data.get("language", ""),
                    duration=float(data.get("duration") or 0),
                    segments=[Segment(**s) for s in data.get("segments", [])],
                )
                summary = ai.summarize(
                    transcript,
                    template=req.get("template", "meeting"),
                    prefer_llm=bool(req.get("prefer_llm", True)),
                    model_name=req.get("summary_model"),
                )
                self._json(200, summary)
            else:
                self._json(404, {"error": "not found"})
        except Exception as exc:  # noqa: BLE001
            self._json(500, {"error": f"{type(exc).__name__}: {exc}"})


def main() -> int:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    llm = ai.llm_model_path()
    print(f"notra ai service on :{PORT} (whisper: {', '.join(MODELS)}; default {DEFAULT_MODEL})", flush=True)
    print(f"summaries: {'llama.cpp · ' + llm.name if llm else 'extractive (no GGUF found)'}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
