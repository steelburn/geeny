"""Search and ask across transcribed takes.

The vendor app keeps its transcripts in the cloud behind a search box; this is the
same idea on hardware you own. The app (or the CLI) hands over the notes it already
has — transcript segments with timestamps and the template summary — and this module
builds a small BM25 index over passages. Retrieval picks the few passages that
matter, so a question does not have to fit a whole library into a 4k context.

Answering then uses the local GGUF (llama.cpp) with numbered excerpts and asks for
citations; without a model the top passages are returned verbatim, so search and
"ask" both work on a machine with no model installed.

No network, no account, nothing leaves the machine.
"""
from __future__ import annotations

import json
import math
import re
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

# --- tokenising -------------------------------------------------------------

_WORD = re.compile(r"[^\W_]+(?:['’][^\W_]+)?", re.UNICODE)
_CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]+")

# Words that carry no retrieval signal. Deliberately small: the IDF term already
# damps common words, and over-filtering breaks short questions like "who owns the
# sampling plan?".
QUESTION_STOPWORDS = set("""
a an the of to in on at for from by with and or but is are was were be been being
do does did done have has had what when where which who whom whose why how that this
these those it its as if then than so we you i he she they them our your their
tell show find me about any all into over under more most other some such
can could would should will shall may might must
""".split())


def tokenize(text: str) -> list[str]:
    """Words, plus CJK character bigrams so scripts without spaces still match."""
    text = (text or "").lower()
    words = [m.group(0) for m in _WORD.finditer(text)]
    for run in _CJK.findall(text):
        words.extend(run[i:i + 2] for i in range(max(0, len(run) - 1)))
    return words


def query_terms(query: str) -> list[str]:
    """Query words with the question filler removed; never empty for real text."""
    terms = tokenize(query)
    kept = [t for t in terms if t not in QUESTION_STOPWORDS]
    return kept or terms


# --- documents --------------------------------------------------------------

@dataclass
class Passage:
    """One retrievable block: a summary section or a run of transcript segments."""

    doc_id: str
    title: str
    date: str
    project: str
    section: str            # "Summary" passages carry the section name
    text: str
    start: float | None     # seconds into the take, None for a summary passage
    end: float | None
    terms: Counter = None   # type: ignore[assignment]

    def hit(self, score: float) -> dict:
        return {
            "id": self.doc_id,
            "title": self.title,
            "date": self.date,
            "project": self.project,
            "section": self.section,
            "text": _snippet(self.text),
            "start": self.start,
            "end": self.end,
            "score": round(score, 3),
        }


def _clean(text: object) -> str:
    return re.sub(r"\s+", " ", str(text or "")).strip()


def _snippet(text: str, limit: int = 280) -> str:
    text = _clean(text)
    if len(text) <= limit:
        return text
    cut = text[:limit]
    space = cut.rfind(" ")
    return (cut[:space] if space > limit * 0.6 else cut).rstrip(" ,;:") + "…"


# Segment runs are cut at this size so a hit is a line or two, not a wall of text.
CHUNK_CHARS = 700
CHUNK_SEGMENTS = 8


def document_passages(doc: dict) -> list[Passage]:
    """Summary sections first, then timestamped runs of the transcript."""
    doc_id = str(doc.get("id") or doc.get("path") or "")
    title = _clean(doc.get("title")) or doc_id
    date = _clean(doc.get("date"))
    project = _clean(doc.get("project"))
    out: list[Passage] = []

    summary = doc.get("summary")
    sections = {}
    if isinstance(summary, dict):
        sections = summary.get("sections") if isinstance(summary.get("sections"), dict) else summary
    if isinstance(sections, dict):
        for name, bullets in sections.items():
            if isinstance(bullets, str):
                bullets = [bullets]
            body = " ".join(_clean(b) for b in (bullets or []) if _clean(b))
            if body:
                out.append(Passage(
                    doc_id=doc_id, title=title, date=date, project=project,
                    section=_clean(name) or "Summary",
                    text=body, start=None, end=None,
                ))

    segments = [s for s in (doc.get("segments") or []) if isinstance(s, dict) and _clean(s.get("text"))]
    run: list[dict] = []
    chars = 0

    def flush() -> None:
        nonlocal run, chars
        if not run:
            return
        text = " ".join(_clean(s.get("text")) for s in run)
        first, last = run[0], run[-1]
        speaker = _clean(first.get("speaker"))
        out.append(Passage(
            doc_id=doc_id, title=title, date=date, project=project,
            section=speaker or "Transcript",
            text=text,
            start=_num(first.get("start")),
            end=_num(last.get("end")),
        ))
        run, chars = [], 0

    for seg in segments:
        text = _clean(seg.get("text"))
        # A speaker change starts a new passage: reading "Speaker 2:" first is how
        # a person finds the answer in the take.
        if run and _clean(seg.get("speaker")) != _clean(run[0].get("speaker")):
            flush()
        run.append(seg)
        chars += len(text) + 1
        if chars >= CHUNK_CHARS or len(run) >= CHUNK_SEGMENTS:
            flush()
    flush()
    return out


def _num(value: object) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


# --- index ------------------------------------------------------------------

class Index:
    """BM25 over passages. Small enough to rebuild on every push from the app."""

    K1 = 1.2
    B = 0.75

    def __init__(self) -> None:
        self._passages: list[Passage] = []
        self._df: Counter = Counter()
        self._avg_len = 1.0
        self._docs: dict[str, dict] = {}
        self.at = 0.0

    def __len__(self) -> int:
        return len(self._passages)

    @property
    def document_count(self) -> int:
        return len(self._docs)

    def replace(self, documents: list[dict]) -> None:
        self._passages = []
        self._docs = {}
        for doc in documents:
            if not isinstance(doc, dict):
                continue
            doc_id = str(doc.get("id") or doc.get("path") or "")
            if not doc_id:
                continue
            self._docs[doc_id] = doc
            for passage in document_passages(doc):
                self._passages.append(passage)

        self._df = Counter()
        total = 0
        for passage in self._passages:
            # The title is a strong signal ("Sampling" questions should reach that
            # take), so it is indexed twice alongside the body.
            tokens = tokenize(passage.text) + tokenize(passage.title) * 2 + tokenize(passage.project)
            passage.terms = Counter(tokens)
            total += sum(passage.terms.values())
            for term in passage.terms:
                self._df[term] += 1
        self._avg_len = (total / len(self._passages)) if self._passages else 1.0
        import time
        self.at = time.time()

    def _idf(self, term: str) -> float:
        n = len(self._passages)
        df = self._df.get(term, 0)
        return math.log(1 + (n - df + 0.5) / (df + 0.5)) if n else 0.0

    def search(self, query: str, limit: int = 12) -> list[dict]:
        terms = query_terms(query)
        if not terms or not self._passages:
            return []
        phrase = _clean(query).lower()
        seen_terms = list(dict.fromkeys(terms))
        scored: list[tuple[float, Passage]] = []
        for passage in self._passages:
            length = sum(passage.terms.values()) or 1
            score = 0.0
            for term in seen_terms:
                tf = passage.terms.get(term, 0)
                if not tf:
                    continue
                norm = self.K1 * (1 - self.B + self.B * length / self._avg_len)
                score += self._idf(term) * (tf * (self.K1 + 1)) / (tf + norm)
            if score <= 0:
                continue
            # An exact phrase match is a much stronger signal than any single word.
            if len(phrase) > 3 and phrase in passage.text.lower():
                score *= 1.4
            if passage.start is None:
                score *= 1.08  # a section summary is a human-written digest
            scored.append((score, passage))
        scored.sort(key=lambda pair: pair[0], reverse=True)

        hits: list[dict] = []
        for score, passage in scored[:max(1, limit)]:
            hits.append(passage.hit(score))
        return hits


def _take_line(hit: dict, number: int) -> str:
    where = ""
    if hit.get("start") is not None:
        seconds = int(hit["start"])
        where = f" · {seconds // 60:02d}:{seconds % 60:02d}"
    elif hit.get("section"):
        where = f" · {hit['section']}"
    return f"[{number}] {hit['title']}{where} — {hit['text']}"


ANSWER_PROMPT = """You answer questions about the user's recorded notes.
Use ONLY the numbered excerpts below. After each fact, cite the excerpt number in
square brackets, like [2]. If the excerpts do not contain the answer, say so in one
short sentence — do not guess and do not invent names, dates or numbers.
Answer in the language of the question. Be brief: one to three sentences, or a
short list when the question asks for several things.

EXCERPTS
{excerpts}

QUESTION: {question}"""


def build_answer(question: str, hits: list[dict], model_name: str | None = None,
                 timeout: float = 180.0) -> dict:
    """Answer from the retrieved passages: local GGUF when present, else verbatim.

    Returns ``{answer, sources, cited, engine}``. ``sources`` carry the take id and
    timestamp so tapping one in the app can seek the player.
    """
    if not hits:
        return {
            "answer": "",
            "sources": [],
            "cited": [],
            "engine": "none",
        }

    excerpts = "\n".join(_take_line(hit, i + 1) for i, hit in enumerate(hits))
    from . import ai  # local import: search works without llama.cpp installed

    # One native model at a time: llama.cpp state is shared inside the library.
    with ai._LLM_LOCK:
        model = ai._gguf_llm(model_name)
        if model is not None:
            try:
                out = model.create_chat_completion(
                    messages=[
                        {"role": "system", "content": "You answer only from the given excerpts, with citations."},
                        {"role": "user", "content": ANSWER_PROMPT.format(excerpts=excerpts, question=question)},
                    ],
                    max_tokens=400,
                    temperature=0.2,
                )
                text = str(out["choices"][0]["message"]["content"]).strip()
                if text:
                    cited = sorted({int(n) for n in re.findall(r"\[(\d+)\]", text)
                                    if 1 <= int(n) <= len(hits)})
                    for i, hit in enumerate(hits, start=1):
                        hit["cited"] = i in cited
                    return {
                        "answer": text,
                        "sources": hits,
                        "cited": cited,
                        "engine": f"llama.cpp · {ai.llm_model_path(model_name).stem}",  # type: ignore[union-attr]
                    }
            except Exception:
                pass  # fall through to the passages themselves

    # No model: the best passages ARE the answer. Never pretended otherwise.
    body = "\n\n".join(hit["text"] for hit in hits[:3])
    cited = list(range(1, min(3, len(hits)) + 1))
    # The app marks a source row by `cited`, so the flags must agree with the list.
    for i, hit in enumerate(hits, start=1):
        hit["cited"] = i in cited
    return {
        "answer": body,
        "sources": hits,
        "cited": cited,
        "engine": "extractive · matching passages",
    }


# --- a library on disk (CLI) -------------------------------------------------

def documents_from_library(directory: str | Path) -> list[dict]:
    """Read `<take>.ogg.notes.json` sidecars + library.json titles/projects."""
    root = Path(directory).expanduser()
    titles: dict[str, str] = {}
    projects: dict[str, str] = {}
    index_file = root / "library.json"
    if index_file.is_file():
        try:
            data = json.loads(index_file.read_text(encoding="utf-8"))
            titles = {str(k): str(v) for k, v in (data.get("titles") or {}).items()}
            projects = {str(k): str(v) for k, v in (data.get("assignments") or {}).items()}
        except (OSError, ValueError):
            pass

    documents: list[dict] = []
    for sidecar in sorted(root.glob("*.notes.json")):
        take = Path(str(sidecar)[: -len(".notes.json")])
        try:
            data = json.loads(sidecar.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or not data.get("segments"):
            continue
        try:
            modified = take.stat().st_mtime
        except OSError:
            modified = sidecar.stat().st_mtime
        # library.json keys the app wrote are absolute; the CLI may walk a relative
        # directory, so both spellings are tried.
        keys = (str(take), str(take.resolve()), take.name)
        documents.append({
            "id": take.name,
            "title": next((titles[k] for k in keys if k in titles), None) or take.stem,
            "date": _date_label(modified),
            "project": next((projects[k] for k in keys if k in projects), ""),
            "duration": data.get("duration") or 0,
            "segments": data.get("segments") or [],
            "summary": data.get("summary") or {},
        })
    return documents


def _date_label(stamp: float) -> str:
    import datetime
    return datetime.datetime.fromtimestamp(stamp).strftime("%d %b · %H:%M")
