"""notra — CLI for the Boya Notra Neo (no vendor app required).

Examples
    python -m notra.cli scan
    python -m notra.cli info
    python -m notra.cli gain 18
    python -m notra.cli raw 0401 18 --channel 0x1e
    python -m notra.cli frames research/capture/ext4/.../btsnoop_hci.log
    python -m notra.cli selftest research/capture/ext4/.../btsnoop_hci.log
"""
from __future__ import annotations

import argparse
import asyncio
import sys

from . import frame as F
from .client import NotraClient
from .transport import BleTransport, ReplayTransport


def _transport(args):
    if getattr(args, "replay", None):
        return ReplayTransport(args.replay)
    return BleTransport(getattr(args, "address", None), debug=args.debug)


async def _cmd_scan(args) -> int:
    from bleak import BleakScanner

    print("scanning 10s ...")
    found = await BleakScanner.discover(timeout=10.0, return_adv=True)
    for addr, (dev, adv) in sorted(found.items(), key=lambda kv: kv[1][1].rssi, reverse=True):
        name = adv.local_name or dev.name or ""
        if name or "notra" in name.lower():
            print(f"{addr}  rssi={adv.rssi:>4}  {name!r}")
    return 0


async def _cmd_info(args) -> int:
    client = NotraClient(_transport(args), debug=args.debug)
    await client.connect()
    try:
        await client.heartbeat()
        info = await client.get_info()
        print(info)
    finally:
        await client.close()
    return 0


async def _cmd_gain(args) -> int:
    client = NotraClient(_transport(args), debug=args.debug)
    await client.connect()
    try:
        await client.heartbeat()
        await client.set_mic_gain(args.db)
        print(f"mic gain -> {args.db} dB")
    finally:
        await client.close()
    return 0


async def _cmd_raw(args) -> int:
    client = NotraClient(_transport(args), debug=True)
    await client.connect()
    try:
        await client.raw(args.hex.replace(" ", ""), channel=int(args.channel, 0), flags=args.flags)
        await asyncio.sleep(args.wait)
    finally:
        await client.close()
    return 0


def _cmd_transcribe(args) -> int:
    from . import ai

    transcript = ai.transcribe(args.path, model_size=args.model)
    if not transcript.segments:
        print("no speech detected")
        return 1
    print(f"{transcript.language} ({transcript.language_probability:.2f}) "
          f"{transcript.duration:.1f}s  {len(transcript.text.split())} words")
    for seg in transcript.segments:
        print(f"  [{seg.start:6.2f} -> {seg.end:6.2f}] {seg.text}")
    if args.save:
        summary = ai.summarize(transcript, template=args.template)
        j, m = ai.save(transcript, summary)
        print(f"saved {j} and {m}")
    return 0


def _cmd_summary(args) -> int:
    from . import ai

    transcript = ai.transcribe(args.path, model_size=args.model)
    summary = ai.summarize(transcript, template=args.template)
    print(ai.to_markdown(transcript, summary))
    if args.save:
        j, m = ai.save(transcript, summary)
        print(f"saved {j} and {m}")
    return 0


def _library_index(args):
    """Search index built from the notes sidecars in a library directory."""
    from . import search

    documents = search.documents_from_library(args.library)
    index = search.Index()
    index.replace(documents)
    if not len(index):
        print(f"no transcripts in {args.library} yet — transcribe a take first", file=sys.stderr)
    return index


def _cmd_find(args) -> int:
    index = _library_index(args)
    hits = index.search(args.query, limit=args.limit)
    if not hits:
        print(f"nothing matches “{args.query}”")
        return 1
    for hit in hits:
        stamp = ("summary" if hit["start"] is None
                 else f"{int(hit['start']) // 60:02d}:{int(hit['start']) % 60:02d}")
        print(f"{hit['score']:>6.2f}  {hit['title']}  · {stamp}")
        print(f"        {hit['text']}")
    return 0


def _cmd_ask(args) -> int:
    from . import search

    index = _library_index(args)
    hits = index.search(args.question, limit=args.limit)
    if not hits:
        print(f"nothing in the notes matches “{args.question}”")
        return 1
    result = search.build_answer(args.question, hits, model_name=args.model)
    print(result["answer"])
    print()
    for i, source in enumerate(result["sources"], start=1):
        stamp = ("summary" if source["start"] is None
                 else f"{int(source['start']) // 60:02d}:{int(source['start']) % 60:02d}")
        mark = "*" if i in result["cited"] else " "
        print(f" {mark}[{i}] {source['title']}  · {stamp}")
    print(f"\n({result['engine']})")
    return 0


def _cmd_frames(args) -> int:
    t = ReplayTransport(args.path)
    shown = 0
    for data in t.iter_sync():
        try:
            fr = F.decode(data)
        except ValueError as exc:
            print(f"  !! {exc}: {data.hex()[:80]}")
            continue
        if args.verbose or shown < args.limit:
            direction = "dev->app" if fr.dst == F.APP_NODE else "?->?"
            print(f"{direction:9s} {fr}")
        shown += 1
    print(f"\n{shown} frames")
    return 0


def _cmd_selftest(args) -> int:
    """Decode every frame in a capture; report valid vs incomplete (capture loss)."""
    t = ReplayTransport(args.path)
    ok = incomplete = 0
    channels: dict[int, int] = {}
    for data in t.iter_sync():
        try:
            fr = F.decode(data)
        except ValueError as exc:
            incomplete += 1
            if args.verbose:
                print(f"  incomplete: {exc}  ({len(data)} bytes)")
            continue
        ok += 1
        channels[fr.channel] = channels.get(fr.channel, 0) + 1

    print(f"frames decoded : {ok}")
    print(f"incomplete     : {incomplete}  (dropped ACL fragments in the snoop log)")
    print("channels       :", {f"0x{k:04x}": v for k, v in sorted(channels.items())})
    return 0 if ok and channels else 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="notra", description="Boya Notra Neo client")
    p.add_argument("--address", help="BLE address (default: scan by name)")
    p.add_argument("--debug", action="store_true", help="dump raw frames")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("scan", help="list nearby BLE devices").set_defaults(fn=lambda a: asyncio.run(_cmd_scan(a)))

    for name, fn, hlp in (
        ("info", _cmd_info, "read name/SN/firmware/battery"),
        ("gain", _cmd_gain, "set mic gain in dB"),
        ("raw", _cmd_raw, "send a raw payload"),
    ):
        sp = sub.add_parser(name, help=hlp)
        sp.add_argument("--replay", help="replay a btsnoop instead of live BLE")
        sp.set_defaults(fn=lambda a, f=fn: asyncio.run(f(a)))
        if name == "gain":
            sp.add_argument("db", type=int)
        if name == "raw":
            sp.add_argument("hex")
            sp.add_argument("--channel", default="0x1e")
            sp.add_argument("--flags", type=lambda s: int(s, 0), default=0x10)
            sp.add_argument("--wait", type=float, default=3.0)

    fp = sub.add_parser("frames", help="print frames from a capture")
    fp.add_argument("path")
    fp.add_argument("--limit", type=int, default=40)
    fp.add_argument("--verbose", action="store_true")
    fp.set_defaults(fn=_cmd_frames)

    tr = sub.add_parser("transcribe", help="transcribe a take (needs faster-whisper)")
    tr.add_argument("path")
    tr.add_argument("--model", default="base", help="whisper model size (tiny/base/small/medium)")
    tr.add_argument("--save", action="store_true", help="also write .json and .md next to the take")
    tr.add_argument("--template", default="plain", choices=["plain", "meeting", "lecture"])
    tr.set_defaults(fn=_cmd_transcribe)

    sm = sub.add_parser("summary", help="transcribe and summarise a take")
    sm.add_argument("path")
    sm.add_argument("--model", default="base")
    sm.add_argument("--template", default="meeting", choices=["plain", "meeting", "lecture"])
    sm.add_argument("--save", action="store_true")
    sm.set_defaults(fn=_cmd_summary)

    st = sub.add_parser("selftest", help="validate every frame in a capture")
    st.add_argument("path")
    st.add_argument("--verbose", action="store_true")
    st.set_defaults(fn=_cmd_selftest)

    fd = sub.add_parser("find", help="search transcripts and summaries")
    fd.add_argument("query")
    fd.add_argument("--library", default=".", help="directory of takes + .notes.json sidecars")
    fd.add_argument("--limit", type=int, default=10)
    fd.set_defaults(fn=_cmd_find)

    ak = sub.add_parser("ask", help="ask a question across the notes")
    ak.add_argument("question")
    ak.add_argument("--library", default=".", help="directory of takes + .notes.json sidecars")
    ak.add_argument("--model", help="GGUF stem to answer with (default: the service default)")
    ak.add_argument("--limit", type=int, default=6)
    ak.set_defaults(fn=_cmd_ask)

    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
