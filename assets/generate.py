#!/usr/bin/env python3
"""Generate every vocaphone brand asset from one set of measured constants.

The mark is a vector reconstruction of the VocaHQ avatar
(https://avatars.githubusercontent.com/u/312860025). The source is only
available as a 460x460 raster, which is too small for a 1024x1024 App Store
icon, so the geometry below was measured off that raster -- stroke widths and
radii by radial scan, colours by sampling -- and re-expressed as paths. The
reconstruction renders within ~1% of the original at 460px, and stays sharp at
any size.

Writing the SVGs needs nothing but the standard library:

    python3 assets/generate.py

Re-rasterising the PNGs additionally needs a renderer, which is deliberately
not a project dependency -- the PNGs are committed:

    pip install cairosvg pillow && python3 assets/generate.py --png
"""

from __future__ import annotations

import argparse
import math
import pathlib

# --- brand ------------------------------------------------------------------

NAVY = "#070F1C"    # the mark
TEAL = "#34BCAE"    # gradient, top
GREEN = "#4DBA64"   # gradient, bottom

# --- geometry, in the 460-unit space of the source avatar --------------------

CX, CY = 228.5, 226.0       # optical centre of the microphone assembly
STROKE = 18.0               # every stroke in the mark is this wide

CAPSULE = dict(x=164.0, y=62.0, w=130.0, h=227.0, r=65.0)
OUTER_ARC = dict(a=165.6, b=141.6, deg=32.5)   # sound arcs are slightly
INNER_ARC = dict(a=129.0, b=99.2, deg=28.5)    # elliptical, not circular
YOKE_R, YOKE_DEG = 87.0, 16.0                  # the yoke is circular
POST_TOP, POST_BOTTOM = 313.0, 382.0           # top hides inside the yoke stroke
BAR_HALF_W, BAR_Y = 58.5, 382.0

DISC = dict(cx=229.0, cy=231.5, r=221.5)       # the badge's round field

MARK_W, MARK_H = 349.0, 329.0                  # mark bounding box
MARK_CX, MARK_CY = 228.5, 226.5                # ...and its centre

# How much of an icon's width the mark spans. Chosen against the iOS squircle
# and the Android 72dp visible area: large enough to read at 60pt, with margin.
ICON_MARK_FRACTION = 0.70

ROOT = pathlib.Path(__file__).resolve().parent


# --- path construction ------------------------------------------------------


def _ellipse_radius(a: float, b: float, deg: float) -> float:
    """Polar radius of the ellipse a/b at `deg` from the horizontal."""
    t = math.radians(deg)
    return 1.0 / math.sqrt((math.cos(t) / a) ** 2 + (math.sin(t) / b) ** 2)


def _sound_arc(spec: dict, side: int) -> str:
    """One sound arc, mirrored about the mark's axis. side: -1 left, +1 right."""
    a, b, deg = spec["a"], spec["b"], spec["deg"]
    r = _ellipse_radius(a, b, deg)
    dx, dy = r * math.cos(math.radians(deg)), r * math.sin(math.radians(deg))
    x = CX + side * dx
    sweep = 0 if side < 0 else 1
    return f"M {x:.2f} {CY - dy:.2f} A {a:.1f} {b:.1f} 0 0 {sweep} {x:.2f} {CY + dy:.2f}"


def _yoke() -> str:
    t = math.radians(YOKE_DEG)
    dx, dy = YOKE_R * math.cos(t), YOKE_R * math.sin(t)
    # large-arc, because the yoke wraps 212 degrees around the capsule
    return (f"M {CX - dx:.2f} {CY - dy:.2f} "
            f"A {YOKE_R:.0f} {YOKE_R:.0f} 0 1 0 {CX + dx:.2f} {CY - dy:.2f}")


def _paths() -> list[tuple[str, str]]:
    """The mark as (kind, d) pairs. kind is 'fill' or 'stroke'."""
    c = CAPSULE
    # the capsule is a stadium: a rect whose corner radius is half its width
    x0, y0, w, h, r = c["x"], c["y"], c["w"], c["h"], c["r"]
    capsule = (f"M {x0:.0f} {y0 + r:.0f} "
               f"A {r:.0f} {r:.0f} 0 0 1 {x0 + w:.0f} {y0 + r:.0f} "
               f"L {x0 + w:.0f} {y0 + h - r:.0f} "
               f"A {r:.0f} {r:.0f} 0 0 1 {x0:.0f} {y0 + h - r:.0f} Z")
    return [
        ("fill", capsule),
        ("stroke", _yoke()),
        ("stroke", f"M {CX:g} {POST_TOP:g} L {CX:g} {POST_BOTTOM:g}"),
        ("stroke", f"M {CX - BAR_HALF_W:g} {BAR_Y:g} L {CX + BAR_HALF_W:g} {BAR_Y:g}"),
        ("stroke", _sound_arc(OUTER_ARC, -1)),
        ("stroke", _sound_arc(OUTER_ARC, +1)),
        ("stroke", _sound_arc(INNER_ARC, -1)),
        ("stroke", _sound_arc(INNER_ARC, +1)),
    ]


def mark_svg(colour: str = NAVY, indent: str = "  ") -> str:
    """The microphone, in the source 460-unit space."""
    out = []
    for kind, d in _paths():
        if kind == "fill":
            out.append(f'{indent}<path d="{d}" fill="{colour}"/>')
        else:
            out.append(f'{indent}<path d="{d}" fill="none" stroke="{colour}" '
                       f'stroke-width="{STROKE:g}" stroke-linecap="round"/>')
    return "\n".join(out)


def _gradient(ident: str = "g", indent: str = "  ") -> str:
    return (f'{indent}<defs>\n'
            f'{indent}  <linearGradient id="{ident}" x1="0" y1="0" x2="0" y2="1">\n'
            f'{indent}    <stop offset="0" stop-color="{TEAL}"/>\n'
            f'{indent}    <stop offset="1" stop-color="{GREEN}"/>\n'
            f'{indent}  </linearGradient>\n'
            f'{indent}</defs>')


# --- documents --------------------------------------------------------------


def logo() -> str:
    """Round badge on a gradient disc. Matches the source avatar."""
    d = DISC
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 460 460" '
            f'width="460" height="460" role="img" aria-label="vocaphone">\n'
            f'{_gradient()}\n'
            f'  <circle cx="{d["cx"]:g}" cy="{d["cy"]:g}" r="{d["r"]:g}" fill="url(#g)"/>\n'
            f'{mark_svg()}\n'
            f'</svg>\n')


def glyph(colour: str = NAVY) -> str:
    """The microphone alone, transparent, trimmed to its bounding box."""
    x0, y0 = MARK_CX - MARK_W / 2, MARK_CY - MARK_H / 2
    return (f'<svg xmlns="http://www.w3.org/2000/svg" '
            f'viewBox="{x0:g} {y0:g} {MARK_W:g} {MARK_H:g}" '
            f'width="{MARK_W:g}" height="{MARK_H:g}" role="img" aria-label="vocaphone">\n'
            f'{mark_svg(colour)}\n'
            f'</svg>\n')


def app_icon(size: int = 1024, background: bool = True,
             colour: str = NAVY, fraction: float = ICON_MARK_FRACTION) -> str:
    """Full-bleed square icon. iOS masks it to a squircle itself, so the
    gradient runs edge to edge rather than sitting in a circle."""
    scale = (size * fraction) / MARK_W
    tx, ty = size / 2 - MARK_CX * scale, size / 2 - MARK_CY * scale
    field = (f'{_gradient()}\n'
             f'  <rect width="{size}" height="{size}" fill="url(#g)"/>\n'
             ) if background else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" '
            f'width="{size}" height="{size}" role="img" aria-label="vocaphone">\n'
            f'{field}'
            f'  <g transform="translate({tx:.3f} {ty:.3f}) scale({scale:.6f})">\n'
            f'{mark_svg(colour, indent="    ")}\n'
            f'  </g>\n'
            f'</svg>\n')


# --- Android ----------------------------------------------------------------

ANDROID_VIEWPORT = 108.0
ANDROID_VISIBLE = 72.0   # the launcher masks away everything outside this


def android_foreground(colour: str = NAVY) -> str:
    """Adaptive-icon foreground: the mark inside the guaranteed-safe centre."""
    span = ANDROID_VISIBLE * ICON_MARK_FRACTION
    scale = span / MARK_W
    tx = ANDROID_VIEWPORT / 2 - MARK_CX * scale
    ty = ANDROID_VIEWPORT / 2 - MARK_CY * scale
    rows = []
    for kind, d in _paths():
        if kind == "fill":
            rows.append(f'            android:fillColor="{colour}"\n'
                        f'            android:pathData="{d}"')
        else:
            rows.append(f'            android:strokeColor="{colour}"\n'
                        f'            android:strokeWidth="{STROKE:g}"\n'
                        f'            android:strokeLineCap="round"\n'
                        f'            android:pathData="{d}"')
    paths = "\n".join(f"        <path\n{r} />" for r in rows)
    return (f'<?xml version="1.0" encoding="utf-8"?>\n'
            f'<!-- Generated by assets/generate.py. Do not edit by hand. -->\n'
            f'<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    android:width="{ANDROID_VIEWPORT:g}dp"\n'
            f'    android:height="{ANDROID_VIEWPORT:g}dp"\n'
            f'    android:viewportWidth="{ANDROID_VIEWPORT:g}"\n'
            f'    android:viewportHeight="{ANDROID_VIEWPORT:g}">\n'
            f'    <group\n'
            f'        android:translateX="{tx:.3f}"\n'
            f'        android:translateY="{ty:.3f}"\n'
            f'        android:scaleX="{scale:.6f}"\n'
            f'        android:scaleY="{scale:.6f}">\n'
            f'{paths}\n'
            f'    </group>\n'
            f'</vector>\n')


def android_background() -> str:
    """Adaptive-icon background: the brand gradient, full bleed.

    The gradient runs across the *visible* window rather than the whole 108dp
    canvas. A launcher only ever shows the central 72dp, so a gradient spanning
    the full canvas would have its first and last sixth masked away and read
    noticeably flatter than the same icon on iOS. Clamping outside that window
    is the default tile mode, so the masked-off margin stays on-brand.
    """
    inset = (ANDROID_VIEWPORT - ANDROID_VISIBLE) / 2
    return (f'<?xml version="1.0" encoding="utf-8"?>\n'
            f'<!-- Generated by assets/generate.py. Do not edit by hand. -->\n'
            f'<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    xmlns:aapt="http://schemas.android.com/aapt"\n'
            f'    android:width="{ANDROID_VIEWPORT:g}dp"\n'
            f'    android:height="{ANDROID_VIEWPORT:g}dp"\n'
            f'    android:viewportWidth="{ANDROID_VIEWPORT:g}"\n'
            f'    android:viewportHeight="{ANDROID_VIEWPORT:g}">\n'
            f'    <path android:pathData="M0,0h{ANDROID_VIEWPORT:g}'
            f'v{ANDROID_VIEWPORT:g}h-{ANDROID_VIEWPORT:g}z">\n'
            f'        <aapt:attr name="android:fillColor">\n'
            f'            <gradient\n'
            f'                android:type="linear"\n'
            f'                android:startX="{ANDROID_VIEWPORT / 2:g}"\n'
            f'                android:startY="{inset:g}"\n'
            f'                android:endX="{ANDROID_VIEWPORT / 2:g}"\n'
            f'                android:endY="{ANDROID_VIEWPORT - inset:g}">\n'
            f'                <item android:offset="0" android:color="{TEAL}"/>\n'
            f'                <item android:offset="1" android:color="{GREEN}"/>\n'
            f'            </gradient>\n'
            f'        </aapt:attr>\n'
            f'    </path>\n'
            f'</vector>\n')


# --- outputs ----------------------------------------------------------------

SVGS: dict[str, object] = {
    "assets/vocaphone-logo.svg": logo,
    "assets/vocaphone-mark.svg": glyph,
    "assets/vocaphone-app-icon.svg": app_icon,
    "server/app/webui/favicon.svg": logo,
    "android/app/src/main/res/drawable/ic_launcher_foreground.xml": android_foreground,
    "android/app/src/main/res/drawable/ic_launcher_background.xml": android_background,
}

# (path, svg-producer, pixel size, opaque). App Store Connect rejects an icon
# that carries an alpha channel, so the primary icon and the Play listing icon
# are flattened to RGB. The iOS 18 dark and tinted variants are the opposite
# case: they keep their transparency, because the system draws its own field
# behind them.
ICONSET = "ios/VocaPhoneApp/Assets.xcassets/AppIcon.appiconset"
PNGS: list[tuple[str, object, int, bool]] = [
    (f"{ICONSET}/icon-1024.png", lambda: app_icon(1024), 1024, True),
    (f"{ICONSET}/icon-1024-dark.png",
     lambda: app_icon(1024, background=False), 1024, False),
    (f"{ICONSET}/icon-1024-tinted.png",
     lambda: app_icon(1024, background=False, colour="#FFFFFF"), 1024, False),
    ("assets/vocaphone-logo-512.png", logo, 512, False),
    ("assets/vocaphone-play-store-512.png", lambda: app_icon(512), 512, True),
]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--png", action="store_true",
                    help="also re-rasterise the PNGs (needs cairosvg)")
    args = ap.parse_args()

    repo = ROOT.parent
    for rel, producer in SVGS.items():
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(producer())
        print(f"wrote {rel}")

    if not args.png:
        print("\nSVGs only. Pass --png to re-rasterise (needs cairosvg).")
        return

    import cairosvg
    from PIL import Image

    for rel, producer, size, opaque in PNGS:
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        cairosvg.svg2png(bytestring=producer().encode(), write_to=str(path),
                         output_width=size, output_height=size)
        if opaque:
            # cairosvg always emits RGBA; drop the channel entirely rather than
            # just making it opaque, which is what Apple's validator checks.
            with Image.open(path) as img:
                img.convert("RGB").save(path)
        print(f"wrote {rel}{' (RGB)' if opaque else ''}")


if __name__ == "__main__":
    main()
