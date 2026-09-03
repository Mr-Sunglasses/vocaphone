#!/usr/bin/env python3
"""Regenerate the shared emoji data files from Unicode and CLDR.

Two files, both read by the Android and iOS keyboards from
`assets/keyboard/emoji/`:

  * `catalog.tsv` — one tab-separated line per emoji: glyph, category, keywords.
    The picker and the panel search use this. Keywords are CLDR annotations,
    plus a few concatenations of the Unicode name (`thumbsup`, `hotdog`,
    `trex`) so a search finds the name people actually type.
  * `suggestions.tsv` — one word to one glyph. The suggestion strip uses this
    while the user is typing a message. It is *not* a dump of the catalog
    keywords: those answer "the" with 🤣 and "is" with the flag of Iceland.
    The strip table is curated chat slang plus the distinctive names Unicode
    and CLDR already give each emoji, with a prose blocklist in between.

Two upstream sources, vendored under tools/unicode/:

  * Unicode's `emoji-test.txt` is authoritative for which emoji exist, which
    group each belongs to, and the order they should appear in.
  * CLDR's annotations are the search keywords.

CLDR is deliberately literal, so a handful of useful search terms are not in
it: nobody annotates a flag with "country". Those live in `emoji-extras.tsv`.
Chat-slang and everyday associations for the strip (`lol`, `dog` → 🐶 rather
than 🐕) live in `emoji-suggestion-overrides.tsv`. Both are short, reviewable
lists rather than rules that quietly edit upstream data.

`--refresh` is the one command that goes out, and its diff is the record of
what changed.

Usage:
    tools/generate-emoji-catalog.py --check      # fail if either file is stale
    tools/generate-emoji-catalog.py --write      # rewrite both
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
SUGGESTIONS = REPOSITORY_ROOT / "assets" / "keyboard" / "emoji" / "suggestions.tsv"
EXTRAS = Path(__file__).resolve().parent / "emoji-extras.tsv"
OVERRIDES = Path(__file__).resolve().parent / "emoji-suggestion-overrides.tsv"
SOURCES = Path(__file__).resolve().parent / "unicode"

# Tokens that appear in Unicode names but should not become a concatenated
# search term on their own (`facewith`, `ando`). One-letter leftovers of a
# hyphenated name (`t` + `rex`) still join.
NAME_STOP = {"with", "and", "of", "the", "a", "in", "on", "at", "to", "for", "or"}

# Auto-generated strip triggers skip these. Curated overrides may still use
# them (none of the current ones do). The test list in EmojiSuggestionsTests
# is the contract: ordinary prose must not attract an emoji.
PROSE_BLOCKLIST = {
    "a", "about", "after", "again", "against", "all", "also", "am", "an", "and",
    "another", "any", "appear", "are", "as", "ask", "at",
    "back", "bad", "be", "because", "become", "been", "before", "begin", "being",
    "believe", "best", "better", "between", "big", "both", "bottom", "bring",
    "build", "but", "buy", "by",
    "came", "can", "check", "code", "cold", "come", "consider", "continue",
    "could", "create", "cut",
    "day", "did", "die", "do", "does", "doing", "done", "during",
    "each", "early", "easy", "end", "even", "every", "expect",
    "fall", "far", "fast", "feel", "few", "find", "first", "follow", "for",
    "free", "from", "front", "full", "further",
    "get", "give", "go", "going", "good", "got", "great", "grow",
    "had", "half", "happen", "hard", "has", "have", "having", "he", "hear",
    "her", "here", "hers", "herself", "high", "him", "himself", "his", "hot",
    "how",
    "i", "if", "in", "include", "into", "is", "it", "its", "itself",
    "just",
    "keep", "key", "know", "known",
    "large", "last", "late", "lead", "learn", "leave", "let", "little", "live",
    "long", "lose", "low",
    "made", "make", "many", "may", "me", "mean", "meet", "more", "most", "move",
    "much", "must", "my", "myself",
    "no", "nor", "not",
    "near", "next", "of", "off", "offer", "old", "on", "once", "only", "open",
    "or", "other", "our", "ours", "ourselves", "out", "over", "own",
    "page", "pay", "play", "pretty", "put",
    "reach", "read", "remain", "remember", "run",
    "real", "same", "second", "see", "seen", "seem", "send", "serve", "set",
    "several", "she", "short", "should", "show", "sit", "slow", "small", "so",
    "some", "speak", "spend", "stand", "start", "stay", "stop", "such",
    "take", "taken", "tell", "than", "that", "the", "their", "theirs", "them",
    "themselves", "then", "there", "these", "they", "third", "this", "those",
    "through", "time", "to", "too", "top",
    "under", "understand", "until", "up", "use",
    "very",
    "wait", "walk", "want", "was", "watch", "we", "were", "what", "when",
    "where", "which", "while", "who", "whole", "whom", "why", "will", "win",
    "with", "without", "work", "worst", "would", "write",
    "young",
    "yes", "you", "your", "yours", "yourself", "yourselves",
}

ZWJ = "\u200d"
MIN_AUTO_WORD = 3
MAX_CONCAT = 24
# Android prefix-matches a unique trigger at most this many letters longer
# than the typed word (`pizz` → pizza). An auto word that is a blocked
# prose word plus one or two letters would make "time" offer ⏲️.
ANDROID_PREFIX_SLACK = 2

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


def load_overrides() -> dict[str, str]:
    """Curated word → glyph. First one wins; later duplicates are ignored."""
    overrides: dict[str, str] = {}
    if not OVERRIDES.exists():
        return overrides
    for line in OVERRIDES.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        word, _, glyph = line.partition("\t")
        word = word.strip().lower()
        glyph = glyph.strip()
        if not word or not glyph or word in overrides:
            continue
        # Digits are allowed here and nowhere else. The auto path below stays
        # alphabetic — `consider` refuses anything that is not — but "100" is
        # how people write 💯 and how a speech model transcribes someone saying
        # "hundred", so the curated list has to be able to say so.
        if not word.isalnum():
            raise SystemExit(
                f"{OVERRIDES.name}: {word!r} is not a plain alphanumeric word"
            )
        overrides[word] = glyph
    return overrides


def concat_name_tokens(tokens: list[str]) -> list[str]:
    """Spellings of a multi-word name without spaces: thumbsup, hotdog, trex.

    Hyphens already split in `normalise`, so T-Rex becomes t + rex and joins
    here. Stop words are dropped from the full-name join so we get
    `facewithtearsofjoy` rather than a string of `with`/`of`/`the`, and from
    adjacent pairs so `with` + `a` does not become `witha`.
    """
    out: list[str] = []
    seen: set[str] = set()

    def add(token: str) -> None:
        if MIN_AUTO_WORD <= len(token) <= MAX_CONCAT and token.isalpha() and token not in seen:
            seen.add(token)
            out.append(token)

    significant = [token for token in tokens if token not in NAME_STOP]
    if len(significant) >= 2:
        add("".join(significant))
    for left, right in zip(tokens, tokens[1:]):
        if left in NAME_STOP or right in NAME_STOP:
            continue
        add(left + right)
    return out


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
        # Concatenated names, so the panel search finds "thumbsup" and "trex"
        # the way people type them, not only "thumbs" + "up".
        name_tokens = normalise(match["name"])
        tts_tokens = normalise(source[0]) if source and source[0] else name_tokens
        for token in concat_name_tokens(name_tokens) + concat_name_tokens(tts_tokens):
            if token not in seen:
                seen.add(token)
                words.append(token)
        lines.append(f"{glyph}\t{category}\t{' '.join(words)}")
    return lines, stats


def iter_base_emoji() -> list[tuple[str, str, str, list[str], list[str]]]:
    """Fully-qualified emoji without skin tones: glyph, unicode name, tts, tokens.

    Skin-tone variants share the base's name, so suggesting them separately
    would put five copies of "thumbs" on the strip. The default (untoned)
    glyph is the one the strip offers; a tone picker is a different feature.
    """
    annotations = load_annotations()
    rows: list[tuple[str, str, str, list[str], list[str]]] = []
    category = None
    for line in read_source("emoji-test.txt").splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            category = CATEGORIES.get(group)
            continue
        match = EMOJI_TEST_LINE.match(line)
        if not match or match["status"] != "fully-qualified" or category is None:
            continue
        glyph = match["glyph"]
        if any(tone in glyph for tone in SKIN_TONES):
            continue
        source = lookup(annotations, glyph) or [match["name"]]
        uname = match["name"]
        tts = source[0] or uname
        rows.append((glyph, uname, tts, normalise(uname), normalise(tts)))
    return rows


def _suggestion_score(
    word: str,
    glyph: str,
    name_tokens: list[str],
    tts_tokens: list[str],
) -> tuple:
    """Lower is better. Exact names beat `red heart`, which beats a long phrase."""
    exact = name_tokens == [word] or tts_tokens == [word]
    face = name_tokens == [word, "face"] or tts_tokens == [word, "face"]
    red = name_tokens == ["red", word] or tts_tokens == ["red", word]
    short = name_tokens[:1] == [word] and len(name_tokens) <= 2
    return (
        0 if exact else 1,
        0 if face else 1,
        0 if red else 1,
        0 if short else 1,
        len(name_tokens),
        1 if ZWJ in glyph else 0,
        len(glyph),
    )


def is_prose_prefix_trap(word: str) -> bool:
    """True if Android prefix matching would fire this on a blocked word.

    `timer` starts with `time` and is only one letter longer, so typing
    "time" would offer ⏲️. The spoken name `timer` is still in the catalog
    for panel search; it just does not go on the strip.
    """
    for blocked in PROSE_BLOCKLIST:
        if len(blocked) < MIN_AUTO_WORD + 1:
            continue
        if word.startswith(blocked) and len(blocked) >= len(word) - ANDROID_PREFIX_SLACK:
            return True
    return False


def _pick_suggestion(
    word: str,
    items: list[tuple[str, list[str], list[str]]],
) -> str | None:
    """The one emoji this word should offer, or none if it is too ambiguous.

    `flamingo` has one owner. `dragon` has three, and the one whose Unicode
    name *is* "dragon" wins over "dragon face" and "mahjong red dragon".
    `face` has a hundred owners and no exact name, so it stays off the strip.
    """
    if not items:
        return None
    ranked = sorted(items, key=lambda item: _suggestion_score(word, *item))
    best = ranked[0]
    score = _suggestion_score(word, *best)
    exact_or_face_or_red = score[0] == 0 or score[1] == 0 or score[2] == 0
    if not exact_or_face_or_red and len(items) > 3:
        return None
    return best[0]


def build_suggestions() -> tuple[list[str], dict[str, int]]:
    """Word → glyph for the suggestion strip, curated first then auto names."""
    overrides = load_overrides()
    emoji = iter_base_emoji()
    known = {glyph for glyph, *_ in emoji}
    stats = {
        "overrides": len(overrides),
        "override_unknown": 0,
        "auto": 0,
        "covered": 0,
        "base": len(emoji),
    }

    table: dict[str, str] = {}
    unknown: list[str] = []
    for word, glyph in overrides.items():
        if glyph not in known:
            stats["override_unknown"] += 1
            unknown.append(f"{word}→{glyph}")
            continue
        table[word] = glyph
    if unknown:
        raise SystemExit(
            f"{OVERRIDES.name} maps to glyphs the catalog does not carry: "
            + ", ".join(unknown)
        )

    by_token: dict[str, list[tuple[str, list[str], list[str]]]] = {}
    by_concat: dict[str, list[tuple[str, list[str], list[str]]]] = {}
    for glyph, _uname, _tts, name_tokens, tts_tokens in emoji:
        item = (glyph, name_tokens, tts_tokens)
        seen: set[str] = set()
        for token in name_tokens + tts_tokens:
            if token in seen:
                continue
            seen.add(token)
            by_token.setdefault(token, []).append(item)
        for token in concat_name_tokens(name_tokens) + concat_name_tokens(tts_tokens):
            by_concat.setdefault(token, []).append(item)

    def consider(word: str, items: list[tuple[str, list[str], list[str]]]) -> None:
        if word in table or word in PROSE_BLOCKLIST or len(word) < MIN_AUTO_WORD:
            return
        if not word.isalpha() or is_prose_prefix_trap(word):
            return
        glyph = _pick_suggestion(word, items)
        if glyph is None:
            return
        table[word] = glyph
        stats["auto"] += 1

    for word, items in by_token.items():
        consider(word, items)
    for word, items in by_concat.items():
        consider(word, items)

    stats["covered"] = len(set(table.values()))
    lines = [f"{word}\t{table[word]}" for word in sorted(table)]
    return lines, stats


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--write", action="store_true", help="rewrite the catalog and suggestions"
    )
    mode.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if either generated file is stale",
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
    generated_catalog = "\n".join(lines) + "\n"
    suggestion_lines, suggestion_stats = build_suggestions()
    generated_suggestions = "\n".join(suggestion_lines) + "\n"

    print(
        f"Emoji {EMOJI_VERSION}, CLDR {CLDR_TAG}: {len(lines)} catalog entries "
        f"({stats['skipped_tone']} toned sequences left out, "
        f"{stats['skipped_component']} components, "
        f"{stats['no_annotation']} without a CLDR annotation); "
        f"{len(suggestion_lines)} suggestion words "
        f"({suggestion_stats['overrides']} curated, "
        f"{suggestion_stats['auto']} from names, "
        f"{suggestion_stats['covered']}/{suggestion_stats['base']} base emoji covered"
        + (
            f", {suggestion_stats['override_unknown']} overrides not in the catalog"
            if suggestion_stats["override_unknown"]
            else ""
        )
        + ")",
        file=sys.stderr,
    )

    outputs = (
        (CATALOG, generated_catalog),
        (SUGGESTIONS, generated_suggestions),
    )

    if arguments.check:
        stale = [
            path.relative_to(REPOSITORY_ROOT)
            for path, generated in outputs
            if (path.read_text(encoding="utf-8") if path.exists() else "") != generated
        ]
        if not stale:
            for path, _ in outputs:
                print(f"{path.relative_to(REPOSITORY_ROOT)} is up to date")
            return 0
        print(
            "stale: "
            + ", ".join(str(path) for path in stale)
            + ". Run tools/generate-emoji-catalog.py --write",
            file=sys.stderr,
        )
        return 1

    for path, generated in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(generated, encoding="utf-8")
        print(f"wrote {path.relative_to(REPOSITORY_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
