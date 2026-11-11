"""Transcription and summaries for Geeny takes.

The vendor app does this in the cloud (Azure Speech + a server-side LLM, see
`research/VENDOR_AI.md`). This module is the local counterpart: whisper for the
transcript, and a template-driven summary that needs no network. If a local
OpenAI-compatible server is running (LM Studio, Ollama, llama.cpp), the summary
is upgraded to an actual LLM; otherwise the extractive template is used.

Optional dependencies (kept out of the package requirements):
    uv run --with faster-whisper --with soundfile --with numpy python -m notra transcribe <ogg>
"""
from __future__ import annotations

import json
import math
import os
import pathlib
import time
import re
import urllib.error
import urllib.request
from dataclasses import dataclass, field, asdict
from pathlib import Path

STOPWORDS = set("""
a about above after again against all am an and any are as at be because been before being
below between both but by can could did do does doing down during each few for from further
had has have having he her here hers herself him himself his how i if in into is it its
itself just me more most my myself no nor not now of off on once only or other our ours
ourselves out over own same she should so some such than that the their theirs them
themselves then there these they this those through to too under until up very was we were
what when where which while who whom why will with you your yours yourself yourselves
okay ok yeah yes um uh oh like really going gonna got get just sort kind thing things
""".split())

TEMPLATES: dict[str, dict[str, list[str]]] = {
    "meeting": {
        "Overview": [],
        "Decisions & actions": [],
        "Key points": [],
    },
    "lecture": {
        "Overview": [],
        "Key concepts": [],
        "To review": [],
    },
    "plain": {
        "Overview": [],
        "Key points": [],
    },
}

ACTION_CUES = (
    "will ", "we need", "need to", "have to", "should ", "let's", "lets ", "going to",
    "next step", "action", "by monday", "by friday", "remember", "todo", "to do",
)

# Long takes are trimmed before the summary prompt: llama.cpp runs with a 4k
# context, and a transcript that overflows produces inconsistent JSON.
MAX_SUMMARY_CHARS = 12000

# Names models actually emit for the canonical template sections.
SECTION_ALIASES: dict[str, list[str]] = {
    "overview": ["summary", "tldr", "abstract", "purpose", "overview & context"],
    "decisions & actions": ["decisions", "actions", "action items", "next steps",
                            "decisions and actions", "decisions actions"],
    "key points": ["points", "highlights", "takeaways", "key takeaways", "main points"],
    "key concepts": ["concepts", "key ideas", "terms", "definitions"],
    "to review": ["review", "follow up", "follow ups", "follow-ups", "questions"],
}


def _section_key(value: object) -> str:
    return re.sub(r"[^a-z0-9]+", " ", str(value).lower()).strip()


def _bullets(value: object) -> list[str]:
    """Plain bullet strings from whatever a model put in a section."""
    out: list[str] = []

    def add(item: object) -> None:
        if item is None:
            return
        if isinstance(item, dict):
            for nested in item.values():
                add(nested)
            return
        if isinstance(item, (list, tuple, set)):
            for nested in item:
                add(nested)
            return
        for line in str(item).splitlines():
            clean = line.strip()
            clean = re.sub(r"^[-*•·]+\s*", "", clean)
            clean = re.sub(r"^\d+[.)]\s*", "", clean)
            clean = clean.strip()
            if clean:
                out.append(clean)

    add(value)
    return out


def normalise_sections(data: object, template: str) -> dict[str, list[str]]:
    """Map a model's output onto the template's headings, in template order."""
    template = template if template in TEMPLATES else "plain"
    order = list(TEMPLATES[template].keys())
    canonical = {_section_key(name): name for name in order}
    aliases: dict[str, str] = {}
    for canonical_name, names in SECTION_ALIASES.items():
        target = canonical.get(_section_key(canonical_name))
        if target:
            for alias in names:
                aliases[_section_key(alias)] = target

    out: dict[str, list[str]] = {name: [] for name in order}
    extras: dict[str, list[str]] = {}
    if isinstance(data, dict):
        for raw_key, raw_value in data.items():
            key = _section_key(raw_key)
            target = canonical.get(key) or aliases.get(key)
            bullets = _bullets(raw_value)
            if target:
                out[target].extend(bullets)
            elif bullets:
                extras[str(raw_key)] = bullets
    out.update(extras)
    return out


@dataclass
class Segment:
    start: float
    end: float
    text: str
    speaker: str | None = None


@dataclass
class Transcript:
    source: str
    language: str = ""
    language_probability: float = 0.0
    duration: float = 0.0
    segments: list[Segment] = field(default_factory=list)

    @property
    def text(self) -> str:
        return " ".join(s.text.strip() for s in self.segments if s.text.strip())

    def to_dict(self) -> dict:
        return asdict(self)


def transcribe(path: str | Path, model_size: str = "base", device: str = "cpu") -> Transcript:
    """Transcribe an Ogg Opus take with faster-whisper (CPU by default)."""
    try:
        import numpy as np
        import soundfile as sf
        from faster_whisper import WhisperModel
    except ImportError as exc:  # pragma: no cover - optional dependency
        raise RuntimeError(
            "transcription needs faster-whisper, soundfile and numpy:\n"
            "  uv run --with faster-whisper --with soundfile --with numpy python -m notra transcribe <file>"
        ) from exc

    audio, rate = sf.read(str(path), dtype="float32", always_2d=False)
    if rate != 16000:
        raise RuntimeError(f"expected 16 kHz mono, got {rate} Hz")
    model = WhisperModel(model_size, device=device, compute_type="int8")
    segments, info = model.transcribe(
        np.ascontiguousarray(audio), vad_filter=True, beam_size=1
    )
    transcript = Transcript(
        source=str(path),
        language=info.language,
        language_probability=float(info.language_probability),
        duration=float(len(audio) / rate),
        segments=[Segment(float(s.start), float(s.end), s.text.strip()) for s in segments],
    )
    # Optional speaker labels; silently skipped when the extra deps are absent.
    try:
        from . import diarize

        as_dicts = [{"start": s.start, "end": s.end, "text": s.text} for s in transcript.segments]
        if diarize.label_speakers(str(path), as_dicts):
            transcript.segments = [
                Segment(d["start"], d["end"], d["text"], d.get("speaker")) for d in as_dicts
            ]
    except Exception:
        pass
    return transcript


# --- extractive summary -----------------------------------------------------

def _sentences(transcript: Transcript) -> list[str]:
    text = transcript.text
    parts = re.split(r"(?<=[.!?])\s+", text)
    out = []
    for p in parts:
        p = p.strip()
        if len(p.split()) >= 3:
            out.append(p)
    return out or ([text] if text else [])


def _score(sentences: list[str]) -> list[tuple[float, int, str]]:
    freq: dict[str, int] = {}
    for s in sentences:
        for w in re.findall(r"[a-zA-Z']+", s.lower()):
            if w in STOPWORDS or len(w) < 3:
                continue
            freq[w] = freq.get(w, 0) + 1
    scored = []
    total = len(sentences)
    for i, s in enumerate(sentences):
        words = [w for w in re.findall(r"[a-zA-Z']+", s.lower()) if w not in STOPWORDS and len(w) >= 3]
        if not words:
            score = 0.0
        else:
            score = sum(freq.get(w, 0) for w in words) / math.sqrt(len(words))
        # Earlier sentences carry more of the framing; long rambles are penalised.
        score *= 1.0 + 0.35 * (1 - i / max(1, total))
        score /= 1.0 + 0.02 * max(0, len(s.split()) - 18)
        scored.append((score, i, s))
    return scored


def summarize_extractive(transcript: Transcript, template: str = "plain") -> dict:
    """Template-shaped summary without an LLM: real sentences, ranked, never invented."""
    template = template if template in TEMPLATES else "plain"
    sentences = _sentences(transcript)
    if not sentences:
        return {"template": template, "sections": {}, "engine": "extractive"}

    scored = _score(sentences)
    ranked = sorted(scored, reverse=True)
    picked: set[int] = set()

    def take(n: int) -> list[str]:
        out = []
        for score, idx, sent in ranked:
            if idx in picked:
                continue
            picked.add(idx)
            out.append(sent)
            if len(out) >= n:
                break
        return out

    sections: dict[str, list[str]] = {name: [] for name in TEMPLATES[template]}

    overview = take(1 if len(sentences) < 4 else 2)
    sections["Overview"] = overview

    actions = [s for _, i, s in ranked if any(cue in s.lower() for cue in ACTION_CUES) and i not in picked]
    action_key = "Decisions & actions" if template == "meeting" else None
    if action_key:
        for s in actions[:3]:
            sections[action_key].append(s)
            picked.add(next(i for i in range(len(sentences)) if sentences[i] == s))

    remaining_key = "Key concepts" if template == "lecture" else "Key points"
    sections[remaining_key] = take(3 if len(sentences) > 4 else 2)

    if template == "lecture":
        sections["To review"] = []

    return {
        "template": template,
        "engine": "extractive",
        "sections": {k: v for k, v in sections.items()},
        "word_count": len(transcript.text.split()),
        "language": transcript.language,
    }


# --- optional LLM summary ---------------------------------------------------

DEFAULT_LLM_NAME = "qwen2.5-1.5b-instruct-q4_k_m"
DEFAULT_LLM = pathlib.Path.home() / ".cache" / "notra" / "models" / f"{DEFAULT_LLM_NAME}.gguf"

# Summary models worth having, smallest first. `fetch_model.py` downloads these by
# name. A bigger model writes tighter notes; only whisper size changes how well
# the audio itself is heard.
MODEL_CATALOG: dict[str, dict[str, object]] = {
    "qwen2.5-1.5b-instruct-q4_k_m": {
        "repo": "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
        "file": "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        "size_gb": 1.1,
        "note": "quick default on CPU — fine for short takes",
    },
    "qwen2.5-3b-instruct-q4_k_m": {
        "repo": "Qwen/Qwen2.5-3B-Instruct-GGUF",
        "file": "qwen2.5-3b-instruct-q4_k_m.gguf",
        "size_gb": 1.9,
        "note": "the CPU sweet spot: better structure and fewer missed actions",
    },
    "llama-3.2-3b-instruct-q4_k_m": {
        "repo": "bartowski/Llama-3.2-3B-Instruct-GGUF",
        "file": "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        "size_gb": 2.0,
        "note": "alternative 3B voice; good English, weaker code-switching",
    },
    "qwen2.5-7b-instruct-q4_k_m": {
        "repo": "Qwen/Qwen2.5-7B-Instruct-GGUF",
        "file": "qwen2.5-7b-instruct-q4_k_m.gguf",
        "size_gb": 4.7,
        "note": "best notes here, roughly 4x the 1.5B wait on CPU",
    },
}


def model_download_url(name: str) -> str | None:
    """Hugging Face URL for a catalog entry, or None for an unknown name."""
    entry = MODEL_CATALOG.get(name)
    if not entry:
        return None
    return f"https://huggingface.co/{entry['repo']}/resolve/main/{entry['file']}"


def summary_catalog() -> list[dict[str, object]]:
    """Models the service can summarise with, plus their download state."""
    installed = set(available_llms())
    out: list[dict[str, object]] = []
    for name, entry in MODEL_CATALOG.items():
        out.append({
            "name": name,
            **entry,
            "downloaded": name in installed,
            "url": model_download_url(name),
        })
    # GGUFs the user dropped in by hand are still selectable.
    for name in sorted(installed - set(MODEL_CATALOG)):
        out.append({"name": name, "downloaded": True, "note": "local file"})
    return out


LOCAL_ENDPOINTS = (
    "http://localhost:1234/v1/chat/completions",  # LM Studio
    "http://localhost:11434/v1/chat/completions",  # Ollama (OpenAI shim)
    "http://localhost:8080/v1/chat/completions",  # llama.cpp server
)


_LLM_CACHE: dict[str, float | str | None] = {"at": 0.0, "url": None}


def _llm_available(max_age: float = 30.0) -> str | None:
    """Cached so a health check never blocks on three dead ports."""
    now = time.time()
    if now - float(_LLM_CACHE["at"] or 0.0) < max_age:
        return _LLM_CACHE["url"]  # type: ignore[return-value]
    found = None
    for url in LOCAL_ENDPOINTS:
        base = url.split("/v1/")[0]
        try:
            with urllib.request.urlopen(f"{base}/v1/models", timeout=0.4) as r:
                if r.status == 200:
                    found = url
                    break
        except (urllib.error.URLError, OSError, ValueError):
            continue
    _LLM_CACHE["at"] = now
    _LLM_CACHE["url"] = found
    return found


def summarize_llm(transcript: Transcript, template: str = "plain", endpoint: str | None = None,
                  model: str | None = None, timeout: float = 90.0) -> dict | None:
    """Ask a local OpenAI-compatible server for a summary; None when unavailable."""
    url = endpoint or _llm_available()
    if url is None:
        return None
    template = template if template in TEMPLATES else "plain"
    schema = json.dumps({name: [] for name in TEMPLATES[template]}, ensure_ascii=False)
    prompt = (
        "Summarise the transcript. Reply with JSON only, no prose, using exactly this shape "
        f"(same keys, same order): {schema}\n"
        "Each value is a list of short plain-text bullet strings drawn from the transcript. "
        "Use the language of the transcript. No markdown, no numbering.\n\nTRANSCRIPT:\n"
        + transcript.text[:MAX_SUMMARY_CHARS]
    )
    body = json.dumps({
        "model": model or "local-model",
        "messages": [
            {"role": "system", "content": "You write terse, factual notes as compact JSON."},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.2,
    }).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = json.loads(r.read())
        content = payload["choices"][0]["message"]["content"]
        data = json.loads(re.search(r"\{.*\}", content, re.S).group(0))
        sections = normalise_sections(data, template)
        if not any(sections.values()):
            return None
        return {"template": template, "engine": "llm", "sections": sections}
    except Exception:
        return None


_GGUF: dict[str, object] = {}
MODELS_DIR = DEFAULT_LLM.parent


def available_llms() -> list[str]:
    """GGUF files the service can summarise with, by name."""
    if not MODELS_DIR.is_dir():
        return []
    return sorted(p.stem for p in MODELS_DIR.glob("*.gguf"))


def llm_model_path(name: str | None = None) -> pathlib.Path | None:
    """Resolve a local GGUF: explicit name, then env, then the default file."""
    if name:
        for cand in (MODELS_DIR / f"{name}.gguf", pathlib.Path(name)):
            if cand.is_file():
                return cand
    env = os.environ.get("NOTRA_LLM_MODEL")
    if env and pathlib.Path(env).is_file():
        return pathlib.Path(env)
    if DEFAULT_LLM.is_file():
        return DEFAULT_LLM
    others = available_llms()
    if others:
        return MODELS_DIR / f"{others[0]}.gguf"
    return None


def download_model(name: str, models_dir: pathlib.Path | str | None = None,
                   progress=None, timeout: float = 120.0) -> pathlib.Path:
    """Fetch a catalog GGUF into the models directory.

    ``progress(done, total)`` is called after each 1 MB block; ``total`` is 0 when
    the server does not send a Content-Length. Interrupted downloads leave no
    partial file behind.
    """
    entry = MODEL_CATALOG.get(name)
    if not entry:
        raise KeyError(f"unknown model {name!r}")
    target_dir = pathlib.Path(models_dir) if models_dir else MODELS_DIR
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / str(entry["file"])
    if target.is_file() and target.stat().st_size > 0:
        return target
    url = model_download_url(name)
    if url is None:
        raise KeyError(f"no download URL for {name!r}")

    part = target.with_name(target.name + ".part")
    done = 0
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response, part.open("wb") as out:
            total = int(response.headers.get("Content-Length") or 0)
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                out.write(block)
                done += len(block)
                if progress:
                    progress(done, total)
        part.replace(target)
    except BaseException:
        part.unlink(missing_ok=True)
        raise
    return target


def _gguf_llm(name: str | None = None):
    path = llm_model_path(name)
    if path is None:
        return None
    model = _GGUF.get(path.stem)
    if model is None:
        try:
            from llama_cpp import Llama
        except ImportError:
            return None
        model = Llama(
            model_path=str(path),
            n_ctx=4096,
            n_threads=max(2, (os.cpu_count() or 4) // 2),
            verbose=False,
        )
        _GGUF[path.stem] = model
    return model


def summarize_gguf(transcript: Transcript, template: str = "plain", model_name: str | None = None,
                   timeout: float = 180.0) -> dict | None:
    """Summarise with a local GGUF (llama.cpp). No network, no account."""
    model = _gguf_llm(model_name)
    if model is None:
        return None
    template = template if template in TEMPLATES else "plain"
    schema = json.dumps({name: [] for name in TEMPLATES[template]}, ensure_ascii=False)
    prompt = (
        "Summarise the transcript. Reply with JSON only, no prose, using exactly this shape "
        f"(same keys, same order): {schema}\n"
        "Each value is a list of short plain-text bullet strings drawn from the transcript. "
        "Use the language of the transcript. No markdown, no numbering.\n\nTRANSCRIPT:\n"
        + transcript.text[:MAX_SUMMARY_CHARS]
    )
    try:
        out = model.create_chat_completion(
            messages=[
                {"role": "system", "content": "You write terse factual notes as compact JSON."},
                {"role": "user", "content": prompt},
            ],
            max_tokens=512,
            temperature=0.2,
            response_format={"type": "json_object"},
        )
        content = out["choices"][0]["message"]["content"]
        match = re.search(r"\{.*\}", content, re.S)
        if not match:
            return None
        data = json.loads(match.group(0))
        sections = normalise_sections(data, template)
        if not any(sections.values()):
            return None
        return {
            "template": template,
            "engine": f"llama.cpp · {llm_model_path(model_name).stem}",  # type: ignore[union-attr]
            "sections": sections,
        }
    except Exception:
        return None


def summarize(transcript: Transcript, template: str = "plain", prefer_llm: bool = True,
              model_name: str | None = None) -> dict:
    """LLM first (local GGUF, then an OpenAI-compatible server), else extractive."""
    if prefer_llm:
        result = summarize_gguf(transcript, template, model_name)   # local llama.cpp
        if result:
            return result
        result = summarize_llm(transcript, template)                # LAN/OpenAI server
        if result:
            return result
    return summarize_extractive(transcript, template)


def make_title(transcript: Transcript, model_name: str | None = None) -> str:
    """A short human title for a take. LLM when available, else the opening words."""
    text = transcript.text.strip()
    if not text:
        return ''
    model = _gguf_llm(model_name)
    if model is not None and len(text.split()) >= 12:
        try:
            out = model.create_chat_completion(
                messages=[
                    {"role": "system", "content": "You write very short, specific titles."},
                    {"role": "user", "content":
                        "Give this transcript a title of 3 to 6 words. Use the language of the "
                        "transcript. Reply with the title only, no quotes, no punctuation at the end.\n\n"
                        + text[:4000]},
                ],
                max_tokens=24,
                temperature=0.3,
            )
            title = out["choices"][0]["message"]["content"].strip().strip('"').strip("'")
            title = title.splitlines()[0][:80].rstrip(" .,:;-")
            if title:
                return title
        except Exception:
            pass
    # fallback: a short, deterministic lead-in from the transcript
    words = text.split()
    return " ".join(words[:7]).rstrip(" .,:;-") + ("…" if len(words) > 7 else "")


# --- rendering --------------------------------------------------------------

def to_markdown(transcript: Transcript, summary: dict) -> str:
    lines = [f"# {Path(transcript.source).name}", ""]
    lines.append(f"_{transcript.duration:.1f}s · {transcript.language or 'unknown'} · "
                 f"{len(transcript.text.split())} words · summary: {summary.get('engine', '?')}_")
    lines.append("")
    for title, bullets in summary.get("sections", {}).items():
        if not bullets:
            continue
        lines.append(f"## {title}")
        for b in bullets:
            lines.append(f"- {b}")
        lines.append("")
    lines.append("## Transcript")
    for s in transcript.segments:
        stamp = f"{int(s.start // 60):02d}:{int(s.start % 60):02d}"
        lines.append(f"- `{stamp}` {s.text}")
    return "\n".join(lines) + "\n"


def save(transcript: Transcript, summary: dict, out_dir: str | Path | None = None) -> tuple[Path, Path]:
    src = Path(transcript.source)
    base = (Path(out_dir) if out_dir else src.parent) / src.stem
    json_path = base.with_suffix(".json")
    md_path = base.with_suffix(".md")
    json_path.write_text(json.dumps({
        "transcript": transcript.to_dict(),
        "summary": summary,
    }, indent=2), encoding="utf-8")
    md_path.write_text(to_markdown(transcript, summary), encoding="utf-8")
    return json_path, md_path
