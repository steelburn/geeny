"""Download a summary GGUF from the Notra model catalog.

Transcription accuracy comes from the whisper size the service runs; this script
only fetches **summary** models. Bigger models write tighter notes and are slower.

    python scripts/fetch_model.py --list
    python scripts/fetch_model.py qwen2.5-3b-instruct-q4_k_m

Files land in `~/.cache/notra/models/` (override with --models-dir or
NOTRA_LLM_DIR), which is where `scripts/ai_server.py` looks.
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
    for unit in ("B", "kB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n:.1f} GB"


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
        print(f" ✓ {name:<34}    —      local file")
    print("\nDownload with: python scripts/fetch_model.py <name>")
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

    part = target.with_suffix(target.suffix + ".part")
    print(f"→ {url}\n  to {target}")
    started = time.time()
    try:
        with urllib.request.urlopen(url) as resp, part.open("wb") as out:
            total = int(resp.headers.get("Content-Length") or 0)
            done = 0
            last = 0.0
            while True:
                block = resp.read(1024 * 256)
                if not block:
                    break
                out.write(block)
                done += len(block)
                now = time.time()
                if now - last > 0.5:
                    last = now
                    pct = f"{done * 100 / total:5.1f}%" if total else ""
                    print(f"\r  {_human(done):>10} {pct}", end="", flush=True)
        part.replace(target)
    except urllib.error.HTTPError as exc:
        part.unlink(missing_ok=True)
        print(f"\ndownload failed: HTTP {exc.code} {exc.reason}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        part.unlink(missing_ok=True)
        print("\ninterrupted — partial file removed", file=sys.stderr)
        return 130
    except OSError as exc:
        part.unlink(missing_ok=True)
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
    args = parser.parse_args(argv)

    if args.list or not args.model:
        return _list()
    return _download(args.model, _models_dir(args.models_dir), args.force)


if __name__ == "__main__":
    sys.exit(main())
