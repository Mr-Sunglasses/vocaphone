#!/usr/bin/env python3
"""Regenerate assets/keyboard/emoji/catalog.tsv from Unicode and CLDR data.

The catalog is one tab-separated line per emoji — glyph, category, keywords —
read by both keyboards from the repository root. It was hand-maintained, with no
record of where its keywords came from, which made two ordinary jobs awkward:
taking a new Unicode release, and answering whether a missing search term was a
deliberate omission or an oversight.

Two upstream sources replace that:

  * Unicode's `emoji-test.txt` is authoritative for which emoji exist, which
    group each belongs to, and the order they should appear in. The order in the
    file is the order the picker shows, and it is the one every other keyboard
    uses, so the grid reads the way people expect.
  * CLDR's annotations are the search keywords, maintained by the same people
    who maintain the rest of the locale data, and available in about a hundred
    languages if emoji search is ever offered in more than English.

CLDR is deliberately literal, so a handful of useful search terms are not in it:
nobody annotates a flag with "country". Those live in `emoji-extras.tsv` next
to this script — a short, reviewable list, rather than a rule that quietly edits
upstream data.

Both sources are vendored under tools/unicode/ rather than downloaded when
this runs. The catalog they produce is shipped in the APK and the IPA, F-Droid
rebuilds it from this tree and compares the result, and a check that reaches
the network fails on someone else's outage and silently changes meaning when
upstream edits a file in place. `--refresh` is the one command that goes out,
and its diff is the record of what changed.

Usage:
    tools/generate-emoji-catalog.py --check      # fail if the catalog is stale
    tools/generate-emoji-catalog.py --write      # rewrite it
    tools/generate-emoji-catalog.py --refresh    # re-download the vendored sources
"""

from __future__ import annotations

import argparse
import re
import sys
import unicodedata
import urllib.request
# defusedxml would be a dependency for a script that has none, to parse two
# files committed in this repository. What the XXE rule is actually about is
# entity expansion, and `parse_annotations` below refuses any document that
# declares an entity or carries an internal DTD subset — which is where both an
# XXE and a billion-laughs payload have to live. CLDR's own
# `<!DOCTYPE ldml SYSTEM ...>` is external, and ElementTree has not fetched
# external DTDs since 3.7.1. The marker has to sit on the line directly above
# the import; anything between the two and Semgrep stops associating them.
# nosemgrep: python.lang.security.use-defused-xml.use-defused-xml
import xml.etree.ElementTree as ElementTree
from pathlib import Path

# Pinned on purpose: an emoji the installed system font does not have renders as
# a blank box, so moving to a newer Unicode release is a decision about the
# devices in the field, not something a rebuild should do on its own.
EMOJI_VERSION = "16.0"
CLDR_TAG = "release-47"

_CLDR_BASE = f"https://raw.githubusercontent.com/unicode-org/cldr/{CLDR_TAG}/common"

# Vendored filename to where --refresh fetches it from.
SOURCE_URLS = {
    "emoji-test.txt": (
        f"https://unicode.org/Public/emoji/{EMOJI_VERSION}/emoji-test.txt"
    ),
    "annotations-en.xml": f"{_CLDR_BASE}/annotations/en.xml",
    "annotationsDerived-en.xml": f"{_CLDR_BASE}/annotationsDerived/en.xml",
}

# annotations holds the single code points, annotationsDerived the sequences —
# flags, keycaps, and every ZWJ combination. Both are needed for full coverage.
ANNOTATION_FILES = ("annotations-en.xml", "annotationsDerived-en.xml")

# Unicode's group names, mapped to the category ids the two keyboards use.
# "Component" — the bare skin-tone and hair modifiers — has no group of its own
# and is not selectable on its own, so it is dropped rather than mapped.
CATEGORIES = {
    "Smileys & Emotion": "smileys",
    "People & Body": "people",
    "Animals & Nature": "animals",
    "Food & Drink": "food",
    "Travel & Places": "travel",
    "Activities": "activities",
    "Objects": "objects",
    "Symbols": "symbols",
    "Flags": "flags",
}

SKIN_TONES = "\U0001F3FB\U0001F3FC\U0001F3FD\U0001F3FE\U0001F3FF"

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPOSITORY_ROOT / "assets" / "keyboard" / "emoji" / "catalog.tsv"
EXTRAS = Path(__file__).resolve().parent / "emoji-extras.tsv"
SOURCES = Path(__file__).resolve().parent / "unicode"

# An internal DTD subset: <!DOCTYPE name [ ... ]>, as opposed to the external
# SYSTEM form CLDR ships. Entity declarations can only appear inside one.
INTERNAL_DTD_SUBSET = re.compile(r"<!DOCTYPE[^>\[]*\[")
ENTITY_DECLARATION = re.compile(r"<!ENTITY", re.IGNORECASE)

EMOJI_TEST_LINE = re.compile(
    r"^(?P<codepoints>[0-9A-F ]+);\s*(?P<status>\S+)\s*#\s*(?P<glyph>\S+)\s+"
    r"E(?P<version>\d+\.\d+)\s+(?P<name>.+)$"
)


def read_source(name: str) -> str:
    path = SOURCES / name
    if not path.exists():
        raise SystemExit(
            f"{path.relative_to(REPOSITORY_ROOT)} is missing. "
            "Run tools/generate-emoji-catalog.py --refresh"
        )
    return path.read_text(encoding="utf-8")


def refresh() -> None:
    """Re-download the vendored sources, so a version bump is one diff."""
    SOURCES.mkdir(exist_ok=True)
    for name, url in SOURCE_URLS.items():
        # The URLs are built from the pinned constants above and nothing else,
        # but urllib would honour a file:// or a plaintext one if that ever
        # stopped being true, and this is the line that would have to notice.
        if not url.startswith("https://"):
            raise SystemExit(f"refusing to fetch {name} over {url!r}")
        print(f"  {url}", file=sys.stderr)
        # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
        with urllib.request.urlopen(url, timeout=120) as response:
            (SOURCES / name).write_bytes(response.read())


def normalise(text: str) -> list[str]:
    """Search tokens from an annotation.

    Hyphens and underscores split rather than survive, so "medium-light skin
    tone" is findable by "light". Everything else that is not a letter or digit
    goes: the shipped file carries tokens like "flag:" and "tone," that only
    match today because both clients happen to compare by prefix.

    ASCII-only, which is right for the English annotations and wrong for any
    other locale — generating one would have to keep the letters of its script
    rather than the a-z range.
    """
    lowered = unicodedata.normalize("NFKC", text).lower()
    return [token for token in re.split(r"[^a-z0-9]+", lowered) if token]


def parse_annotations(name: str) -> ElementTree.Element:
    """A vendored CLDR annotation file, parsed once its DTD is known to be inert.

    See the note on the ElementTree import. The check is cheap and exact: an
    entity has to be declared to be referenced, and a declaration has to sit in
    an internal DTD subset, so refusing both leaves nothing for an expansion
    attack to stand on.
    """
    text = read_source(name)
    if INTERNAL_DTD_SUBSET.search(text) or ENTITY_DECLARATION.search(text):
        raise SystemExit(
            f"{name} carries an internal DTD subset or an entity declaration. "
            "CLDR does not ship either; refusing to parse it."
        )
    return ElementTree.fromstring(text)


def load_annotations() -> dict[str, list[str]]:
    """Glyph to its CLDR name followed by its keywords, in CLDR's own order."""
    keywords: dict[str, list[str]] = {}
    names: dict[str, str] = {}
    for name in ANNOTATION_FILES:
        root = parse_annotations(name)
        for annotation in root.iter("annotation"):
            glyph = annotation.get("cp")
            if glyph is None:
                continue
            text = annotation.text or ""
            if annotation.get("type") == "tts":
                names.setdefault(glyph, text)
            else:
                keywords.setdefault(glyph, []).extend(
                    part.strip() for part in text.split("|") if part.strip()
                )
    return {
        glyph: [names.get(glyph, "")] + keywords.get(glyph, [])
        for glyph in set(names) | set(keywords)
    }


def load_extras() -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """Search terms CLDR does not carry, by glyph and by category.

    A key beginning with `@` names a category and applies to everything in it.
    Flags are why: CLDR annotates each one with its country and nothing else, so
    without a rule the whole tab becomes unfindable by the words people actually
    reach for. Two hundred and seventy identical per-glyph lines would say the
    same thing while hiding that it is one decision.
    """
    per_glyph: dict[str, list[str]] = {}
    per_category: dict[str, list[str]] = {}
    if not EXTRAS.exists():
        return per_glyph, per_category
    for line in EXTRAS.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        key, _, words = line.partition("\t")
        if not words:
            continue
        if key.startswith("@"):
            per_category[key[1:]] = words.split()
        else:
            per_glyph[key] = words.split()
    return per_glyph, per_category


def lookup(annotations: dict[str, list[str]], glyph: str) -> list[str] | None:
    """The annotation for a glyph, allowing for how CLDR spells its keys.

    Two mismatches with `emoji-test.txt`, and both are silent — a miss falls
    back to the Unicode name, which reads fine and quietly halves that emoji's
    search terms:

      * CLDR omits U+FE0F from most keys, where emoji-test always writes the
        fully-qualified form. This alone accounted for 365 of them.
      * A toned sequence has no entry of its own, because CLDR annotates the
        base and expects the client to compose the tone name.
    """
    variation_selector = "️"
    untoned = "".join(c for c in glyph if c not in SKIN_TONES)
    for candidate in (
        glyph,
        glyph.replace(variation_selector, ""),
        untoned,
        untoned.replace(variation_selector, ""),
    ):
        found = annotations.get(candidate)
        if found is not None:
            return found
    return None


def build(keep_skin_tones: bool) -> tuple[list[str], dict[str, int]]:
    annotations = load_annotations()
    extras, category_extras = load_extras()
    lines: list[str] = []
    stats = {"skipped_component": 0, "skipped_tone": 0, "no_annotation": 0}
    category = None

    for line in read_source("emoji-test.txt").splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            # A group Unicode adds later would otherwise be dropped in silence,
            # taking every emoji in it with no tab to show they are missing.
            # "Component" is the one that is meant to go: bare skin-tone and
            # hair modifiers, which are not selectable on their own.
            if group not in CATEGORIES and group != "Component":
                raise SystemExit(
                    f"emoji-test.txt has a group this generator does not know: "
                    f"{group!r}. Add it to CATEGORIES, or to the line above if "
                    f"it is deliberately not shown."
                )
            category = CATEGORIES.get(group)
            continue
        match = EMOJI_TEST_LINE.match(line)
        # Only fully-qualified sequences: the rest are the same emoji written
        # without its variation selector, which would show as a duplicate.
        if not match or match["status"] != "fully-qualified":
            continue
        if category is None:
            stats["skipped_component"] += 1
            continue
        glyph = match["glyph"]
        if not keep_skin_tones and any(tone in glyph for tone in SKIN_TONES):
            stats["skipped_tone"] += 1
            continue

        words: list[str] = []
        seen: set[str] = set()
        source = lookup(annotations, glyph)
        if source is None:
            stats["no_annotation"] += 1
            source = [match["name"]]
        tail = extras.get(glyph, []) + category_extras.get(category, [])
        for chunk in list(source) + tail:
            for token in normalise(chunk):
                if token not in seen:
                    seen.add(token)
                    words.append(token)
        lines.append(f"{glyph}\t{category}\t{' '.join(words)}")
    return lines, stats


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="rewrite the catalog")
    mode.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if the catalog differs from what this would generate",
    )
    mode.add_argument(
        "--refresh",
        action="store_true",
        help=(
            "re-download the vendored Unicode and CLDR sources; the only mode "
            "that touches the network"
        ),
    )
    parser.add_argument(
        "--skin-tones",
        choices=("inline", "base"),
        default="inline",
        help=(
            "inline (default) lists all five toned forms of every emoji that "
            "has them, matching the shipped catalog; base lists each emoji "
            "once, which halves the file but needs a tone picker in the UI "
            "before a toned emoji can be reached at all"
        ),
    )
    arguments = parser.parse_args()

    if arguments.refresh:
        refresh()
        print(
            f"refreshed tools/unicode/ from Emoji {EMOJI_VERSION} and CLDR "
            f"{CLDR_TAG}. Review the diff, then --write."
        )
        return 0

    lines, stats = build(keep_skin_tones=arguments.skin_tones == "inline")
    generated = "\n".join(lines) + "\n"

    print(
        f"Emoji {EMOJI_VERSION}, CLDR {CLDR_TAG}: {len(lines)} entries "
        f"({stats['skipped_tone']} toned sequences left out, "
        f"{stats['skipped_component']} components, "
        f"{stats['no_annotation']} without a CLDR annotation)",
        file=sys.stderr,
    )

    if arguments.check:
        current = CATALOG.read_text(encoding="utf-8") if CATALOG.exists() else ""
        if current == generated:
            print(f"{CATALOG.relative_to(REPOSITORY_ROOT)} is up to date")
            return 0
        print(
            f"{CATALOG.relative_to(REPOSITORY_ROOT)} does not match the "
            f"generator. Run tools/generate-emoji-catalog.py --write",
            file=sys.stderr,
        )
        return 1

    CATALOG.write_text(generated, encoding="utf-8")
    print(f"wrote {CATALOG.relative_to(REPOSITORY_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
