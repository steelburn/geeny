"""Draw the Geeny launcher icon and write every asset that uses it.

The mark is the app's own material: forest stock, paper ink, one sage recording
light, and a geometric **G** for Geeny. No gradients, no glow, two colours and a
dot.

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
RADIUS = 0.22              # rounded-square corner

CX = CY = 0.5
R_OUT = 0.290              # G ring, outer radius
R_IN = 0.175               # G ring, inner radius
OPENING = 30.0             # half-angle of the mouth on the right, degrees

CROSSBAR = (0.460, 0.455, 0.760, 0.545)   # x0, y0, x1, y1
CONNECTOR = (0.690, 0.455, 0.770, 0.658)  # the G's spur, down to the lower arc
SPUR_RADIUS = 0.020

LIGHT = (0.800, 0.220, 0.026)             # cx, cy, r — the recording light


def _round_rect(x: float, y: float, x0: float, y0: float, x1: float, y1: float,
                r: float) -> bool:
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hw, hh = (x1 - x0) / 2, (y1 - y0) / 2
    qx = abs(x - cx) - (hw - r)
    qy = abs(y - cy) - (hh - r)
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r <= 0


def _glyph(x: float, y: float) -> bool:
    dx, dy = x - CX, y - CY
    distance = math.hypot(dx, dy)
    angle = math.degrees(math.atan2(dy, dx))
    ring = R_IN <= distance <= R_OUT and not (-OPENING <= angle <= OPENING)
    if ring:
        return True
    if _round_rect(x, y, *CROSSBAR, SPUR_RADIUS):
        return True
    if _round_rect(x, y, *CONNECTOR, SPUR_RADIUS):
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


def _p(v: float) -> str:
    return f"{v * 108:.2f}".rstrip("0").rstrip(".")


def _rect_path(x0: float, y0: float, x1: float, y1: float, r: float) -> str:
    """Rounded-rectangle path in 108-unit viewport coordinates."""
    X0, Y0, X1, Y1, R = _p(x0), _p(y0), _p(x1), _p(y1), _p(r)
    return (f"M{X0},{Y0} H{X1} V{Y1} H{X0} Z"
            if r <= 0 else
            f"M{_p(x0 + r)},{Y0} H{_p(x1 - r)} A{R},{R} 0 0 1 {X1},{_p(y0 + r)} "
            f"V{_p(y1 - r)} A{R},{R} 0 0 1 {_p(x1 - r)},{Y1} H{_p(x0 + r)} "
            f"A{R},{R} 0 0 1 {X0},{_p(y1 - r)} V{_p(y0 + r)} "
            f"A{R},{R} 0 0 1 {_p(x0 + r)},{Y0} Z")


def _ring_path() -> str:
    """Annular sector: the G's body, open on the right."""
    a = math.radians(OPENING)
    ox, oy = CX + R_OUT * math.cos(-a), CY + R_OUT * math.sin(-a)
    oy2 = CY + R_OUT * math.sin(a)
    ix, iy = CX + R_IN * math.cos(-a), CY + R_IN * math.sin(-a)
    iy2 = CY + R_IN * math.sin(a)
    return (f"M{_p(ox)},{_p(oy)} A{_p(R_OUT)},{_p(R_OUT)} 0 1 0 "
            f"{_p(ox)},{_p(oy2)} L{_p(ix)},{_p(iy2)} "
            f"A{_p(R_IN)},{_p(R_IN)} 0 1 1 {_p(ix)},{_p(iy)} Z")


def _fg_xml() -> str:
    lx, ly, lr = LIGHT
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/make_icon.py — edit the script, not this file. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:pathData="{_ring_path()}" android:fillColor="#F5F3ED" />
    <path android:pathData="{_rect_path(*CROSSBAR, SPUR_RADIUS)}" android:fillColor="#F5F3ED" />
    <path android:pathData="{_rect_path(*CONNECTOR, SPUR_RADIUS)}" android:fillColor="#F5F3ED" />
    <path android:pathData="M{_p(lx - lr)},{_p(ly)} a{_p(lr)},{_p(lr)} 0 1 0 {_p(lr * 2)},0 a{_p(lr)},{_p(lr)} 0 1 0 {_p(-lr * 2)},0 Z"
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
    lx, ly, lr = LIGHT
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">
  <!-- Geeny: forest stock, paper G, one sage recording light. -->
  <rect width="108" height="108" rx="{_p(RADIUS)}" fill="#175C44"/>
  <circle cx="{_p(lx)}" cy="{_p(ly)}" r="{_p(lr)}" fill="#E3EDE7"/>
  <path d="{_ring_path()}" fill="#F5F3ED"/>
  <path d="{_rect_path(*CROSSBAR, SPUR_RADIUS)}" fill="#F5F3ED"/>
  <path d="{_rect_path(*CONNECTOR, SPUR_RADIUS)}" fill="#F5F3ED"/>
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
