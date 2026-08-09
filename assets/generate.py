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

BRAND = "#0F6B57"   # the flat field, and the primary action colour in every app
INK = "#0B1A15"     # the mark on a light ground
LIGHT = "#F2F6F2"   # the mark on the brand field

# The mark is light on the brand field, not dark. A near-black mark on #0F6B57
# puts two dark colours against each other: measured at the size an icon is
# actually seen -- 44px on a home screen, 22px in a settings row -- the arcs
# disappear first and then the yoke, leaving a smudge. INK is for light grounds
# only, and it is a green-biased near-black rather than the navy it replaces, so
# the mark belongs to the same palette as everything drawn around it.

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

# The shipped mark draws the inner sound arcs only. Four arcs instead of six is
# what makes the microphone legible at 22px: the outer pair sits closest to the
# icon's edge, is the first thing to blur, and costs the mic 20% of its drawn
# size to make room for. "both" still produces the full avatar reconstruction --
# see README.md, which records what that reconstruction is for.
SHIPPED_ARCS = "inner"

# How much of an icon the mark's longest side spans. Measured against the iOS
# squircle and Android's 72dp visible area: large enough to read at 60pt with
# margin to spare. It applies to the longest side rather than the width because
# the four-arc mark is taller than it is wide, and scaling that off the width
# would run it out of both safe areas.
ICON_MARK_FRACTION = 0.68

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


def _paths(arcs: str = SHIPPED_ARCS) -> list[tuple[str, str]]:
    """The mark as (kind, d) pairs. kind is 'fill' or 'stroke'.

    `arcs` is "inner" for the shipped four-arc mark, or "both" for the full
    six-arc reconstruction of the source avatar.
    """
    c = CAPSULE
    # the capsule is a stadium: a rect whose corner radius is half its width
    x0, y0, w, h, r = c["x"], c["y"], c["w"], c["h"], c["r"]
    capsule = (f"M {x0:.0f} {y0 + r:.0f} "
               f"A {r:.0f} {r:.0f} 0 0 1 {x0 + w:.0f} {y0 + r:.0f} "
               f"L {x0 + w:.0f} {y0 + h - r:.0f} "
               f"A {r:.0f} {r:.0f} 0 0 1 {x0:.0f} {y0 + h - r:.0f} Z")
    out = [
        ("fill", capsule),
        ("stroke", _yoke()),
        ("stroke", f"M {CX:g} {POST_TOP:g} L {CX:g} {POST_BOTTOM:g}"),
        ("stroke", f"M {CX - BAR_HALF_W:g} {BAR_Y:g} L {CX + BAR_HALF_W:g} {BAR_Y:g}"),
    ]
    if arcs == "both":
        out += [("stroke", _sound_arc(OUTER_ARC, -1)),
                ("stroke", _sound_arc(OUTER_ARC, +1))]
    return out + [("stroke", _sound_arc(INNER_ARC, -1)),
                  ("stroke", _sound_arc(INNER_ARC, +1))]


def mark_box(arcs: str = SHIPPED_ARCS) -> tuple[float, float, float, float]:
    """(width, height, centre-x, centre-y) of the mark as drawn, stroke included.

    An arc's widest point is its horizontal, where the ellipse's radius is `a`,
    not its endpoints -- so the outer pair is what sets the width when it is
    drawn. Vertically the capsule and the base bar always win, which is why the
    height does not depend on `arcs`. For "both" this reproduces the 349x329 box
    that was previously written out as constants.
    """
    half_w = (OUTER_ARC["a"] if arcs == "both" else INNER_ARC["a"]) + STROKE / 2
    top, bottom = CAPSULE["y"], BAR_Y + STROKE / 2
    return 2 * half_w, bottom - top, CX, (top + bottom) / 2


def mark_svg(colour: str = INK, indent: str = "  ", arcs: str = SHIPPED_ARCS) -> str:
    """The microphone, in the source 460-unit space."""
    out = []
    for kind, d in _paths(arcs):
        if kind == "fill":
            out.append(f'{indent}<path d="{d}" fill="{colour}"/>')
        else:
            out.append(f'{indent}<path d="{d}" fill="none" stroke="{colour}" '
                       f'stroke-width="{STROKE:g}" stroke-linecap="round"/>')
    return "\n".join(out)


# --- documents --------------------------------------------------------------


def logo(background: str = BRAND, colour: str = LIGHT) -> str:
    """Round badge on a flat disc."""
    d = DISC
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 460 460" '
            f'width="460" height="460" role="img" aria-label="vocaphone">\n'
            f'  <circle cx="{d["cx"]:g}" cy="{d["cy"]:g}" r="{d["r"]:g}" fill="{background}"/>\n'
            f'{mark_svg(colour)}\n'
            f'</svg>\n')


def glyph(colour: str = INK) -> str:
    """The microphone alone, transparent, trimmed to its bounding box."""
    w, h, cx, cy = mark_box()
    x0, y0 = cx - w / 2, cy - h / 2
    return (f'<svg xmlns="http://www.w3.org/2000/svg" '
            f'viewBox="{x0:g} {y0:g} {w:g} {h:g}" '
            f'width="{w:g}" height="{h:g}" role="img" aria-label="vocaphone">\n'
            f'{mark_svg(colour)}\n'
            f'</svg>\n')


def app_icon(size: int = 1024, background: bool = True,
             colour: str = LIGHT, fraction: float = ICON_MARK_FRACTION) -> str:
    """Full-bleed square icon. iOS masks it to a squircle itself."""
    w, h, cx, cy = mark_box()
    scale = (size * fraction) / max(w, h)
    tx, ty = size / 2 - cx * scale, size / 2 - cy * scale
    field = (f'  <rect width="{size}" height="{size}" fill="{BRAND}"/>\n'
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


def android_foreground(colour: str = LIGHT) -> str:
    """Adaptive-icon foreground: the mark inside the guaranteed-safe centre."""
    w, h, cx, cy = mark_box()
    scale = (ANDROID_VISIBLE * ICON_MARK_FRACTION) / max(w, h)
    tx = ANDROID_VIEWPORT / 2 - cx * scale
    ty = ANDROID_VIEWPORT / 2 - cy * scale
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
    """Adaptive-icon background: a flat brand field, full bleed."""
    return (f'<?xml version="1.0" encoding="utf-8"?>\n'
            f'<!-- Generated by assets/generate.py. Do not edit by hand. -->\n'
            f'<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    android:width="{ANDROID_VIEWPORT:g}dp"\n'
            f'    android:height="{ANDROID_VIEWPORT:g}dp"\n'
            f'    android:viewportWidth="{ANDROID_VIEWPORT:g}"\n'
            f'    android:viewportHeight="{ANDROID_VIEWPORT:g}">\n'
            f'    <path\n'
            f'        android:fillColor="{BRAND}"\n'
            f'        android:pathData="M0,0h{ANDROID_VIEWPORT:g}'
            f'v{ANDROID_VIEWPORT:g}h-{ANDROID_VIEWPORT:g}z" />\n'
            f'</vector>\n')


# --- outputs ----------------------------------------------------------------

# Every path here is inside *this* repository. The gateway favicon used to be in
# this dict as `server/app/webui/favicon.svg`, and it cannot be any more: `server/`
# is the VocaHQ/vocagateway submodule, so writing there made a routine
# `generate.py` run dirty a second repository as a side effect. Nothing in
# vocaphone's `git status` shows it, so the honest failure mode was to regenerate,
# commit here, and silently leave the favicon behind in an uncommitted submodule.
# It is `--favicon` now: same drawing, but you have to ask for it. See
# `gateway_favicon`.
SVGS: dict[str, object] = {
    "assets/vocaphone-logo.svg": logo,
    "assets/vocaphone-mark.svg": glyph,
    "assets/vocaphone-app-icon.svg": app_icon,
    "android/app/src/main/res/drawable/ic_launcher_foreground.xml": android_foreground,
    "android/app/src/main/res/drawable/ic_launcher_background.xml": android_background,
}


def gateway_favicon() -> str:
    """The gateway WebUI's favicon, which belongs to VocaHQ/vocagateway.

    Kept here because the geometry and the palette are here, and a second copy of
    the generator in the gateway repo would be the worse duplication. The gateway
    takes a neutral disc rather than the brand field: it draws the mark small
    against its own dark chrome, where a green disc reads as a smudge of colour.
    """
    return logo("#ECECEC", colour="#171717")

# (path, svg-producer, pixel size, opaque). App Store Connect rejects an icon
# that carries an alpha channel, so the primary icon and the Play listing icon
# are flattened to RGB. The iOS 18 dark and tinted variants are the opposite
# case: they keep their transparency, because the system draws its own field
# behind them -- and because that field is dark, the dark variant takes the same
# light mark as the brand field does, not INK.
ICONSET = "ios/VocaPhoneApp/Assets.xcassets/AppIcon.appiconset"
PNGS: list[tuple[str, object, int, bool]] = [
    (f"{ICONSET}/icon-1024.png", lambda: app_icon(1024), 1024, True),
    (f"{ICONSET}/icon-1024-dark.png",
     lambda: app_icon(1024, background=False), 1024, False),
    (f"{ICONSET}/icon-1024-tinted.png",
     lambda: app_icon(1024, background=False, colour="#FFFFFF"), 1024, False),
    ("ios/VocaPhoneApp/Assets.xcassets/BrandMark.imageset/brand-mark.png",
     lambda: app_icon(256, background=False), 256, False),
    ("assets/vocaphone-logo-512.png", logo, 512, False),
    ("assets/vocaphone-play-store-512.png", lambda: app_icon(512), 512, True),
]


# --- brand rules ------------------------------------------------------------


def _relative_luminance(colour: str) -> float:
    """WCAG relative luminance. Channels have to be linearised first."""
    value = colour.lstrip("#")
    channels = []
    for index in range(3):
        raw = int(value[index * 2:index * 2 + 2], 16) / 255
        channels.append(raw / 12.92 if raw <= 0.03928 else ((raw + 0.055) / 1.055) ** 2.4)
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def contrast(first: str, second: str) -> float:
    a, b = _relative_luminance(first), _relative_luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)


# Mark against the ground it is drawn on, for every variant this file emits. 3:1
# is the WCAG floor for a graphic, and the rule exists because the icon this
# replaced was navy on the brand field at 2.98:1 -- a smudge at the size an icon
# is actually seen. Dark-on-brand is the specific mistake to keep out.
MARK_ON_GROUND = [
    ("logo badge", LIGHT, BRAND),
    ("app icon", LIGHT, BRAND),
    ("gateway favicon", "#171717", "#ECECEC"),
]


def check() -> list[str]:
    """Assert the brand rules the shipped assets are supposed to satisfy.

    Returns a list of failures, empty when everything holds. This is what makes
    the guideline testable rather than remembered: it would have caught the
    dark-variant regression in the shared org pack, where the mark went back to
    ink on the brand field at 2.78:1.
    """
    failures = []

    for name, mark, ground in MARK_ON_GROUND:
        measured = contrast(mark, ground)
        if measured < 3.0:
            failures.append(f"{name}: mark {mark} on {ground} is {measured:.2f}:1, below 3:1")

    # The shipped mark is the four-arc simplification; see README.md. Six is the
    # avatar reconstruction and must stay reachable, and must stay 349x329.
    shipped, full = len(_paths()), len(_paths("both"))
    if shipped != 6:
        failures.append(f"shipped mark draws {shipped} paths, expected 6 (four arcs)")
    if full != 8:
        failures.append(f"six-arc mark draws {full} paths, expected 8")
    box = mark_box("both")
    if box != (349.2, 329.0, 228.5, 226.5):
        failures.append(f"the avatar reconstruction's box moved: {box}")

    # The mark has to fit Android's guaranteed-visible circle.
    width, height, _, _ = mark_box()
    scale = (ANDROID_VISIBLE * ICON_MARK_FRACTION) / max(width, height)
    diagonal = math.hypot(width * scale, height * scale)
    if diagonal > ANDROID_VISIBLE:
        failures.append(
            f"the adaptive icon's mark is {diagonal:.1f}dp diagonal, "
            f"outside the {ANDROID_VISIBLE:g}dp visible circle"
        )

    if INK == "#070F1C":
        failures.append("INK is still the old blue-biased navy")
    return failures


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="verify the brand rules and exit; writes nothing")
    ap.add_argument("--png", action="store_true",
                    help="also re-rasterise the PNGs (needs cairosvg)")
    ap.add_argument("--favicon", metavar="PATH", type=pathlib.Path,
                    help="also write the gateway favicon to PATH, e.g. "
                         "server/app/webui/favicon.svg -- that file belongs to "
                         "VocaHQ/vocagateway and has to be committed there")
    args = ap.parse_args()

    if args.check:
        failures = check()
        for failure in failures:
            print(f"FAIL  {failure}")
        if failures:
            raise SystemExit(1)
        print("brand rules hold")
        return

    repo = ROOT.parent
    for rel, producer in SVGS.items():
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(producer())
        print(f"wrote {rel}")

    # Taken as given rather than resolved against the repo root, because the
    # whole point of the flag is that the destination is somewhere else.
    if args.favicon is not None:
        args.favicon.parent.mkdir(parents=True, exist_ok=True)
        args.favicon.write_text(gateway_favicon())
        print(f"wrote {args.favicon} -- vocagateway's file, commit it there")

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
