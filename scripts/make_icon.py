"""Draw the Notra launcher icon and write every Android asset that uses it.

The mark is the app's own material: forest ink, paper stock, and a microphone
built from a ruled stand — plus one sage "recording light". No gradients, no
glow, two colours and a dot.

    python scripts/make_icon.py

Outputs (regenerated deterministically, safe to re-run):

    app/android/app/src/main/res/mipmap-*/ic_launcher.png    legacy launcher icons
    app/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml
    app/android/app/src/main/res/drawable/ic_launcher_foreground.xml
    app/android/app/src/main/res/values/colors.xml
    app/assets/brand/icon.svg                                source preview
    web/favicon.svg                                          browser console mark
"""
from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "app" / "android" / "app" / "src" / "main" / "res"

FOREST = (0x17, 0x5C, 0x44)
PAPER = (0xF5, 0xF3, 0xED)
SAGE = (0xE3, 0xED, 0xE7)

# --- geometry, in normalized 0..1 icon units -------------------------------
RADIUS = 0.22

CAPSULE = (0.425, 0.200, 0.575, 0.520)   # x0, y0, x1, y1
CAPSULE_R = 0.075

ARC_CENTER = (0.5, 0.50)
ARC_R = 0.175
STROKE = 0.045                            # full stroke width

STEM = ((0.5, 0.675), (0.5, 0.745))
BASE = ((0.40, 0.78), (0.60, 0.78))

LIGHT = (0.725, 0.295, 0.028)             # cx, cy, r


def _round_rect(x: float, y: float, x0: float, y0: float, x1: float, y1: float,
                r: float) -> bool:
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hw, hh = (x1 - x0) / 2, (y1 - y0) / 2
    qx = abs(x - cx) - (hw - r)
    qy = abs(y - cy) - (hh - r)
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r <= 0


def _segment(x: float, y: float, a: tuple[float, float], b: tuple[float, float],
             half: float) -> bool:
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    span = dx * dx + dy * dy
    t = 0.0 if span == 0 else max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / span))
    return math.hypot(x - (ax + t * dx), y - (ay + t * dy)) <= half


def _glyph(x: float, y: float) -> bool:
    if _round_rect(x, y, *CAPSULE, CAPSULE_R):
        return True
    cx, cy = ARC_CENTER
    if y >= cy and abs(math.hypot(x - cx, y - cy) - ARC_R) <= STROKE / 2:
        return True
    if _segment(x, y, *STEM, STROKE / 2) or _segment(x, y, *BASE, STROKE / 2):
        return True
    return False


def _render(master: int = 768) -> list[tuple[int, int, int, int]]:
    """One sample per master pixel; downsampling supplies the anti-aliasing."""
    px: list[tuple[int, int, int, int]] = []
    for j in range(master):
        y = (j + 0.5) / master
        for i in range(master):
            x = (i + 0.5) / master
            if not _round_rect(x, y, 0, 0, 1, 1, RADIUS):
                px.append((0, 0, 0, 0))
                continue
            lx, ly, lr = LIGHT
            if math.hypot(x - lx, y - ly) <= lr:
                px.append((*SAGE, 255))
            elif _glyph(x, y):
                px.append((*PAPER, 255))
            else:
                px.append((*FOREST, 255))
    return px


def _downsample(src: list[tuple[int, int, int, int]], master: int, n: int) -> bytes:
    out = bytearray()
    span = master / n
    for j in range(n):
        y0, y1 = j * span, (j + 1) * span
        ys = [v for v in range(master) if y0 <= v + 0.5 < y1]
        for i in range(n):
            x0, x1 = i * span, (i + 1) * span
            xs = [v for v in range(master) if x0 <= v + 0.5 < x1]
            r = g = b = a = 0
            for sy in ys:
                row = sy * master
                for sx in xs:
                    pr, pg, pb, pa = src[row + sx]
                    r += pr * pa
                    g += pg * pa
                    b += pb * pa
                    a += pa
            count = max(1, len(xs) * len(ys))
            if a == 0:
                out += b"\x00\x00\x00\x00"
            else:
                out += bytes((r // a, g // a, b // a, a // count))
    return bytes(out)


def _png(path: Path, n: int, rgba: bytes) -> None:
    rows = bytearray()
    stride = n * 4
    for y in range(n):
        rows.append(0)
        rows += rgba[y * stride:(y + 1) * stride]

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    blob = b"\x89PNG\r\n\x1a\n"
    blob += chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
    blob += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    blob += chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(blob)


def _fg_xml() -> str:
    def p(v: float) -> str:
        return f"{v * 108:.2f}".rstrip("0").rstrip(".")

    x0, y0, x1, y1 = CAPSULE
    cx, cy = ARC_CENTER
    r = CAPSULE_R
    midx = (x0 + x1) / 2
    cap = (f"M{p(midx)},{p(y0)} A{p(r)},{p(r)} 0 0 1 {p(x1)},{p(y0 + r)} "
           f"L{p(x1)},{p(y1 - r)} A{p(r)},{p(r)} 0 0 1 {p(x0)},{p(y1 - r)} "
           f"L{p(x0)},{p(y0 + r)} A{p(r)},{p(r)} 0 0 1 {p(midx)},{p(y0)} Z")
    arc = (f"M{p(cx - ARC_R)},{p(cy)} A{p(ARC_R)},{p(ARC_R)} 0 0 1 "
           f"{p(cx + ARC_R)},{p(cy)}")
    stem = f"M{p(STEM[0][0])},{p(STEM[0][1])} L{p(STEM[1][0])},{p(STEM[1][1])}"
    base = f"M{p(BASE[0][0])},{p(BASE[0][1])} L{p(BASE[1][0])},{p(BASE[1][1])}"
    lx, ly, lr = LIGHT
    stroke = f'android:strokeColor="#F5F3ED" android:strokeWidth="{p(STROKE)}" ' \
             'android:strokeLineCap="round"'
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/make_icon.py — edit the script, not this file. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:pathData="{cap}" android:fillColor="#F5F3ED" />
    <path android:pathData="{arc}" {stroke} android:fillColor="@android:color/transparent" />
    <path android:pathData="{stem}" {stroke} android:fillColor="@android:color/transparent" />
    <path android:pathData="{base}" {stroke} android:fillColor="@android:color/transparent" />
    <path android:pathData="M{p(lx - lr)},{p(ly)} a{p(lr)},{p(lr)} 0 1 0 {p(lr * 2)},0 a{p(lr)},{p(lr)} 0 1 0 {p(-lr * 2)},0 Z"
        android:fillColor="#E3EDE7" />
</vector>
"""


def _adaptive_xml() -> str:
    return """<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/make_icon.py -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
"""


def _svg() -> str:
    def p(v: float) -> str:
        return f"{v * 108:.2f}".rstrip("0").rstrip(".")

    x0, y0, x1, y1 = CAPSULE
    cx, cy = ARC_CENTER
    r = CAPSULE_R
    midx = (x0 + x1) / 2
    lx, ly, lr = LIGHT
    cap = (f"M{p(midx)},{p(y0)} A{p(r)},{p(r)} 0 0 1 {p(x1)},{p(y0 + r)} "
           f"L{p(x1)},{p(y1 - r)} A{p(r)},{p(r)} 0 0 1 {p(x0)},{p(y1 - r)} "
           f"L{p(x0)},{p(y0 + r)} A{p(r)},{p(r)} 0 0 1 {p(midx)},{p(y0)} Z")
    arc = (f"M{p(cx - ARC_R)},{p(cy)} A{p(ARC_R)},{p(ARC_R)} 0 0 1 "
           f"{p(cx + ARC_R)},{p(cy)}")
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">
  <!-- Notra: forest stock, paper mic, one sage recording light. -->
  <rect width="108" height="108" rx="{p(RADIUS)}" fill="#175C44"/>
  <circle cx="{p(lx)}" cy="{p(ly)}" r="{p(lr)}" fill="#E3EDE7"/>
  <path d="{cap}" fill="#F5F3ED"/>
  <path d="{arc}" fill="none" stroke="#F5F3ED" stroke-width="{p(STROKE)}" stroke-linecap="round"/>
  <path d="M{p(STEM[0][0])},{p(STEM[0][1])} L{p(STEM[1][0])},{p(STEM[1][1])}" fill="none"
        stroke="#F5F3ED" stroke-width="{p(STROKE)}" stroke-linecap="round"/>
  <path d="M{p(BASE[0][0])},{p(BASE[0][1])} L{p(BASE[1][0])},{p(BASE[1][1])}" fill="none"
        stroke="#F5F3ED" stroke-width="{p(STROKE)}" stroke-linecap="round"/>
</svg>
"""


def main() -> int:
    master = _render()
    for density, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                        ("xxhdpi", 144), ("xxxhdpi", 192)):
        _png(RES / f"mipmap-{density}" / "ic_launcher.png", px,
             _downsample(master, 768, px))
        print(f"wrote mipmap-{density}/ic_launcher.png ({px} px)")

    (RES / "drawable").mkdir(parents=True, exist_ok=True)
    (RES / "drawable" / "ic_launcher_foreground.xml").write_text(_fg_xml(), encoding="utf-8")
    (RES / "mipmap-anydpi-v26").mkdir(parents=True, exist_ok=True)
    (RES / "mipmap-anydpi-v26" / "ic_launcher.xml").write_text(_adaptive_xml(), encoding="utf-8")
    (RES / "values").mkdir(parents=True, exist_ok=True)
    (RES / "values" / "colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Generated by scripts/make_icon.py -->\n"
        "<resources>\n"
        '    <color name="ic_launcher_background">#175C44</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )
    (ROOT / "app" / "assets" / "brand").mkdir(parents=True, exist_ok=True)
    (ROOT / "app" / "assets" / "brand" / "icon.svg").write_text(_svg(), encoding="utf-8")
    (ROOT / "web").mkdir(parents=True, exist_ok=True)
    (ROOT / "web" / "favicon.svg").write_text(_svg(), encoding="utf-8")
    print("wrote drawable + anydpi-v26 + colors.xml + icon.svg + favicon.svg")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
