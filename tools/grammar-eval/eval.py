#!/usr/bin/env python3
"""Scores infer.py on dictation_en.jsonl, or on the typed sets.

    python3 eval.py MODEL_DIR                 # the shipped recipe, writes results.md
    python3 eval.py MODEL_DIR --compare       # alignment and guard ablations too
    python3 eval.py MODEL_DIR --set typed     # typed_en.jsonl, writes results-typed.md
    python3 eval.py MODEL_DIR --set clean     # clean_en.jsonl, writes results-clean.md

The typed sets are scored the way Writing check offers the model's edits on
typed text, word edit by word edit: a capital the model puts anywhere but a
sentence start, or anywhere in text typed in lower case, and a full stop it
adds where the text stops, are taken back first (see `as_typed` and
`WritingCheck.offeredOnTypedText` in both apps).
"""

from __future__ import annotations

import argparse
import collections
import difflib
import json
import re
import statistics
from pathlib import Path

from infer import LATIN_WORD, PROTECTED, WORD, Tagger

HERE = Path(__file__).parent


def edits(src: str, dst: str) -> set[tuple]:
    a, b = WORD.findall(src), WORD.findall(dst)
    ops = difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_opcodes()
    return {(i1, i2, tuple(b[j1:j2])) for tag, i1, i2, j1, j2 in ops if tag != "equal"}


def protected_items(text: str) -> list[str]:
    """What must survive verbatim: masked spans, numbers, and mid-sentence names."""
    items = [m.group(0) for m in PROTECTED.finditer(text)]
    words = WORD.findall(text)
    for i, w in enumerate(words):
        if any(c.isdigit() for c in w):
            items.append(w)
        elif LATIN_WORD.fullmatch(w) and w[0].isupper() and i > 0 \
                and words[i - 1] not in ".!?" and w != "I" and not w.startswith("I'"):
            items.append(w)
    return items


def damaged(src: str, out: str) -> list[str]:
    """Every protected occurrence the output lost, counted rather than merely
    looked for: "Kevin met Kevin" → "Kevin met Alex" lost one Kevin."""
    src_words = collections.Counter(WORD.findall(src))
    out_words = collections.Counter(WORD.findall(out))
    lost = []
    for item in dict.fromkeys(protected_items(src)):
        if WORD.fullmatch(item):
            wanted, have = src_words[item], out_words[item]
        else:
            wanted, have = src.count(item), out.count(item)
        lost += [item] * max(0, wanted - have)
    return lost


def _diff(a: list[str], b: list[str]) -> list[tuple[int, int, int, int]]:
    """`ModelEdits.diff` in both apps: the changed runs by longest common
    subsequence once the shared start and end are set aside, ties deleting
    from `a` first."""
    prefix = 0
    while prefix < len(a) and prefix < len(b) and a[prefix] == b[prefix]:
        prefix += 1
    suffix = 0
    while suffix < len(a) - prefix and suffix < len(b) - prefix and a[-1 - suffix] == b[-1 - suffix]:
        suffix += 1
    x, y = a[prefix:len(a) - suffix], b[prefix:len(b) - suffix]
    n, m = len(x), len(y)
    if not n or not m:
        return [(prefix, prefix + n, prefix, prefix + m)] if n or m else []
    lcs = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            lcs[i][j] = lcs[i + 1][j + 1] + 1 if x[i] == y[j] else max(lcs[i + 1][j], lcs[i][j + 1])
    hunks, i, j, open_ = [], 0, 0, None
    while i < n or j < m:
        if i < n and j < m and x[i] == y[j]:
            if open_:
                hunks.append((prefix + open_[0], prefix + i, prefix + open_[1], prefix + j))
                open_ = None
            i, j = i + 1, j + 1
        else:
            open_ = open_ or (i, j)
            if j >= m or (i < n and lcs[i + 1][j] >= lcs[i][j + 1]):
                i += 1
            else:
                j += 1
    if open_:
        hunks.append((prefix + open_[0], prefix + i, prefix + open_[1], prefix + j))
    return hunks


def _hunks(a: list[str], b: list[str]) -> list[tuple[int, int, int, int]]:
    """`ModelEdits.hunks`: compared without case, so a capital is its own edit,
    and a run of one-for-one swaps split into one edit per word."""
    key = lambda w: w.lower().replace("’", "'")
    out, i, j = [], 0, 0
    for a1, a2, b1, b2 in _diff([key(w) for w in a], [key(w) for w in b]) + [(len(a), len(a), len(b), len(b))]:
        for k in range(min(a1 - i, b1 - j)):
            if a[i + k] != b[j + k]:
                out.append((i + k, i + k + 1, j + k, j + k + 1))
        if a2 - a1 == b2 - b1 > 1:
            out += [(a1 + k, a1 + k + 1, b1 + k, b1 + k + 1) for k in range(a2 - a1)]
        elif (a1, a2, b1, b2) != (len(a), len(a), len(b), len(b)):
            out.append((a1, a2, b1, b2))
        i, j = a2, b2
    return out


def as_typed(src: str, out: str) -> str:
    """What the keyboard would offer, edit by edit as `WritingCheck.offeredOnTypedText`
    filters the model's word edits: no full stop, question or exclamation mark
    added where the text stops, and no capital except at a sentence start in
    text not typed in lower case ("i" is always capitalised). Replacing a mark
    the text already has is kept; the dropped edits are taken back from `out`."""
    a, b = list(WORD.finditer(src)), list(WORD.finditer(out))
    at, bt = [m.group(0) for m in a], [m.group(0) for m in b]
    letter = next((c for c in src if c.isalpha()), "")
    lowercase_style = letter.islower()
    openers = set("\"“'‘([«")

    def sentence_start(i: int) -> bool:
        while i > 0 and at[i - 1] in openers:
            i -= 1
        return i == 0 or at[i - 1] in (".", "!", "?", "…") or "\n" in src[a[i - 1].end():a[i].start()]

    reverts = []  # (start, end, text) spans of `out` to put back
    for a1, a2, b1, b2 in _hunks(at, bt):
        removed, added = at[a1:a2], bt[b1:b2]
        if not removed and added and all(c in ".!?" for w in added for c in w):
            after = src[a[a1 - 1].end() if a1 else 0:]
            if not after.strip() or after.lstrip(" \t").startswith("\n"):
                reverts.append((b[b1].start(), b[b2 - 1].end(), ""))
            continue
        if removed and len(removed) == len(added) and \
                all(x.lower().replace("’", "'") == y.lower().replace("’", "'") for x, y in zip(removed, added)):
            first = removed[0].lower().replace("’", "'")
            if first != "i" and not first.startswith("i'") and (lowercase_style or not sentence_start(a1)):
                reverts.append((b[b1].start(), b[b2 - 1].end(), src[a[a1].start():a[a2 - 1].end()]))
    for start, end, text in sorted(reverts, reverse=True):
        head = out[:start].rstrip(" \t") if not text else out[:start]
        out = head + text + out[end:]
    return out


def score(tagger: Tagger, cases: list[dict], typed: bool = False) -> dict:
    tp = fp = fn = 0
    clean = clean_changed = noisy = noisy_exact = 0
    damage, lat, fps, misses = [], [], [], []
    for c in cases:
        r = tagger.correct(c["input"], frozenset(c.get("vocabulary", [])))
        lat.append(r.millis)
        out = as_typed(c["input"], r.output) if typed else r.output
        lost = damaged(c["input"], out)
        if lost:
            damage.append((c["input"], out, lost))
        # Edit-level counts cover every case: an edit to a correct sentence is
        # a false positive too, and must cost precision.
        g, h = edits(c["input"], c["expected"]), edits(c["input"], out)
        tp += len(g & h)
        fp += len(h - g)
        fn += len(g - h)
        if c["input"] == c["expected"]:
            clean += 1
            if out != c["input"]:
                clean_changed += 1
                fps.append((c["input"], out))
            continue
        noisy += 1
        noisy_exact += out == c["expected"]
        if out != c["expected"]:
            misses.append((c["input"], out, c["expected"]))
    p = tp / (tp + fp) if tp + fp else 0.0
    rc = tp / (tp + fn) if tp + fn else 0.0
    f = 1.25 * p * rc / (0.25 * p + rc) if p + rc else 0.0
    lat.sort()
    return {
        "n": len(cases), "clean": clean, "noisy": noisy,
        "precision": p, "recall": rc, "f05": f,
        "exact": noisy_exact / noisy if noisy else 0.0,
        "fpr": clean_changed / clean if clean else 0.0,
        "damage": len(damage),
        "p50": statistics.median(lat), "p95": lat[int(0.95 * (len(lat) - 1))],
        "false_positives": fps, "damaged": damage, "misses": misses,
    }


def row(name: str, s: dict) -> str:
    return (f"| {name} | {s['precision']:.3f} | {s['recall']:.3f} | {s['f05']:.3f} | "
            f"{s['exact']:.1%} | {s['fpr']:.1%} | {s['damage']} | "
            f"{s['p50']:.1f} | {s['p95']:.1f} |")


HEADER = ("| Configuration | Precision | Recall | F0.5 | Exact (errors) | "
          "False-positive rate (correct) | Protected-span damage | p50 ms | p95 ms |\n"
          "|---|---|---|---|---|---|---|---|---|")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir", type=Path)
    ap.add_argument("--compare", action="store_true")
    ap.add_argument("--set", choices=("dictation", "typed", "clean"), default="dictation")
    args = ap.parse_args()
    typed = args.set != "dictation"
    source = HERE / ("dictation_en.jsonl" if not typed else f"{args.set}_en.jsonl")
    cases = [json.loads(l) for l in source.read_text().splitlines() if l.strip()]

    shipped = Tagger(args.model_dir)
    for c in cases[:20]:
        shipped.correct(c["input"])  # warm up before timing
    main_score = score(shipped, cases, typed)
    lines = [HEADER, row("shipped recipe", main_score)]
    if args.compare:
        variants = {
            "no guard or protections, KEEP bias 3.0": dict(guard=False),
            "guard, KEEP bias 0": dict(keep_bias=0.0),
            "guard, KEEP bias 2.0 (the v1.5 recipe)": dict(keep_bias=2.0),
            "guard, KEEP bias 4.0 (Only sure fixes)": dict(keep_bias=4.0),
            "alignment: no [BOS]": dict(alignment="nobos-space-first"),
            "alignment: first word without Ġ": dict(alignment="bos-nospace-first"),
            "alignment: last subtoken": dict(alignment="bos-space-last"),
            "protected spans fed as placeholders": dict(feed_spans=False),
        }
        for name, kw in variants.items():
            lines.append(row(name, score(Tagger(args.model_dir, **kw), cases, typed)))
    table = "\n".join(lines)
    print(table)

    def listing(title, items, fmt):
        return [f"\n### {title} ({len(items)})\n"] + [fmt(*x) for x in items]

    kind = "dictation-style" if not typed else f"{args.set} (typed, as offered)"
    detail = [f"# Results\n\n{main_score['clean']} correct and {main_score['noisy']} "
              f"erroneous {kind} sentences. Generated by `eval.py`.\n", table]
    detail += listing("Correct sentences the stage changed", main_score["false_positives"],
                      lambda a, b: f"- `{a}` → `{b}`")
    detail += listing("Protected spans lost", main_score["damaged"],
                      lambda a, b, l: f"- `{a}` → `{b}` (lost {l})")
    detail += listing("Error sentences not fixed exactly", main_score["misses"],
                      lambda a, b, e: f"- `{a}` → `{b}` (expected `{e}`)")
    name = "results.md" if not typed else f"results-{args.set}.md"
    (HERE / name).write_text("\n".join(detail).rstrip("\n") + "\n")


if __name__ == "__main__":
    main()
