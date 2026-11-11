"""Download a summary GGUF from the Geeny model catalog.

Transcription accuracy comes from the whisper size the service runs; this script
only fetches **summary** models. Bigger models write tighter notes and are slower.

    python scripts/fetch_model.py --list
    python scripts/fetch_model.py qwen2.5-3b-instruct-q4_k_m
    python scripts/fetch_model.py --storage
    python scripts/fetch_model.py --delete qwen2.5-3b-instruct-q4_k_m
    python scripts/fetch_model.py --delete whisper:small

Files land in `~/.cache/notra/models/` (override with --models-dir or
NOTRA_LLM_DIR), which is where `scripts/ai_server.py` looks. Whisper weights live in
the Hugging Face cache; both are listed by `--storage` and removable without
touching anything else.
"""
from __future__ import annotations

import argparse
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from notra import ai  # noqa: E402

# Windows consoles default to cp1252; the catalog notes use an em dash.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass


def _human(n: float) -> str:
    """Decimal units, matching the app's housekeeping panel and the catalog sizes."""
    if n >= 1e9:
        return f"{n / 1e9:.2f} GB"
    if n >= 1e6:
        return f"{n / 1e6:.0f} MB"
    if n >= 1e3:
        return f"{n / 1e3:.0f} kB"
    return f"{int(n)} B"


def _models_dir(arg: str | None) -> Path:
    if arg:
        return Path(arg).expanduser()
    env = os.environ.get("NOTRA_LLM_DIR")
    return Path(env).expanduser() if env else ai.MODELS_DIR


def _list() -> int:
    installed = set(ai.available_llms())
    print(f"models in {ai.MODELS_DIR}\n")
    for name, entry in ai.MODEL_CATALOG.items():
        mark = "✓" if name in installed else " "
        print(f" {mark} {name:<34} {entry['size_gb']:>4} GB  {entry['note']}")
    extras = sorted(installed - set(ai.MODEL_CATALOG))
    for name in extras:
        size = (ai.MODELS_DIR / f"{name}.gguf").stat().st_size
        print(f" ✓ {name:<34} {_human(size):>7}  local file")
    print("\nDownload with: python scripts/fetch_model.py <name>")
    print("Free space with: python scripts/fetch_model.py --storage")
    return 0


def _storage() -> int:
    data = ai.model_storage()
    entries = data["models"]
    if not entries:
        print("no downloaded models — nothing to clean up")
        return 0
    labels = {"summary": "summary", "speech": "whisper", "partial": "partial"}
    for entry in entries:
        print(f" {labels.get(entry['kind'], entry['kind']):<8} {entry['name']:<38} "
              f"{_human(entry['bytes']):>10}")
    print(f"\n {len(entries)} model(s), {_human(data['total_bytes'])} on this machine")
    print(f" summary models: {data['models_dir']}")
    print(f" whisper cache : {data['whisper_cache']}")
    print("\nDelete one with: python scripts/fetch_model.py --delete <name>")
    print("Whisper sizes need the kind: --delete whisper:small")
    return 0


def _delete(token: str) -> int:
    kind, _, name = token.partition(":")
    if not name:
        kind, name = "summary", token
    try:
        freed = ai.delete_model(kind, name)
    except FileNotFoundError as exc:
        print(f"not found: {exc}", file=sys.stderr)
        return 2
    except (ValueError, OSError) as exc:
        print(f"could not delete: {exc}", file=sys.stderr)
        return 1
    print(f"deleted {kind} {name} — freed {_human(freed)}")
    if kind == "speech":
        print("It downloads again the next time the service transcribes with that size.")
    return 0


def _prune_parts() -> int:
    """Remove interrupted downloads; they never resume, so they only take space."""
    parts = sorted(ai.MODELS_DIR.glob("*.part")) if ai.MODELS_DIR.is_dir() else []
    if not parts:
        print("no partial downloads")
        return 0
    freed = 0
    for part in parts:
        size = part.stat().st_size
        part.unlink(missing_ok=True)
        freed += size
        print(f" removed {part.name} ({_human(size)})")
    print(f"freed {_human(freed)}")
    return 0


def _download(name: str, models_dir: Path, force: bool) -> int:
    entry = ai.MODEL_CATALOG.get(name)
    if entry is None:
        print(f"unknown model {name!r}; run --list", file=sys.stderr)
        return 2
    url = ai.model_download_url(name)
    assert url is not None
    models_dir.mkdir(parents=True, exist_ok=True)
    target = models_dir / str(entry["file"])
    if target.is_file() and not force:
        print(f"already there: {target} ({_human(target.stat().st_size)})")
        return 0
    if force:
        target.unlink(missing_ok=True)

    print(f"→ {url}\n  to {target}")
    started = time.time()
    last = 0.0

    def progress(done: int, total: int) -> None:
        nonlocal last
        now = time.time()
        if now - last <= 0.5:
            return
        last = now
        pct = f"{done * 100 / total:5.1f}%" if total else ""
        print(f"\r  {_human(done):>10} {pct}", end="", flush=True)

    try:
        ai.download_model(name, models_dir=models_dir, progress=progress)
    except KeyboardInterrupt:
        print("\ninterrupted — partial file removed", file=sys.stderr)
        return 130
    except urllib.error.HTTPError as exc:
        print(f"\ndownload failed: HTTP {exc.code} {exc.reason}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 - surface a helpful message
        print(f"\ndownload failed: {exc}", file=sys.stderr)
        return 1

    took = time.time() - started
    print(f"\ndone in {took:.0f}s — {target.stat().st_size / 1e9:.2f} GB")
    print("It appears in the app's Summary picker after Test connection.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("model", nargs="?", help="catalog name, e.g. qwen2.5-3b-instruct-q4_k_m")
    parser.add_argument("--list", action="store_true", help="show the catalog and what is installed")
    parser.add_argument("--models-dir", help="override the model directory")
    parser.add_argument("--force", action="store_true", help="download even if the file exists")
    parser.add_argument("--storage", action="store_true", help="what the models take on disk")
    parser.add_argument("--delete", metavar="NAME",
                        help="remove a downloaded model (whisper sizes as whisper:small)")
    parser.add_argument("--prune-parts", action="store_true",
                        help="remove interrupted .part downloads")
    args = parser.parse_args(argv)

    if args.storage:
        return _storage()
    if args.delete:
        return _delete(args.delete)
    if args.prune_parts:
        return _prune_parts()
    if args.list or not args.model:
        return _list()
    return _download(args.model, _models_dir(args.models_dir), args.force)


if __name__ == "__main__":
    sys.exit(main())
