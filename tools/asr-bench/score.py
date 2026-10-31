#!/usr/bin/env python3
"""Score what the benchmark decoded against the reference transcripts.

    uv run --with-requirements tools/asr-bench/requirements.txt \\
        python tools/asr-bench/score.py                       # every tag and model
    ... score.py --tag baseline --compare vad-split           # two runs side by side

Reads `<dir>/results/<tag>/<model>/<set>.<path>.jsonl`, written by
`AccuracyBenchmarkTests`, and the matching `sets/<set>/manifest.jsonl`.

English uses the Whisper English normaliser, as the Open ASR Leaderboard does,
so casing, punctuation, spelled-out numbers and British spellings are not
counted as errors. Hindi keeps its vowel signs: Whisper's basic normaliser
strips combining marks, which turns different Devanagari words into the same
string. It reports character error rate beside WER, since Hindi word
boundaries vary between transcribers.

`raw` is the model's text; `finished` is what the keyboard types after the
app's own repair, digits and styling. A gap between the two is the finishing
stage gaining or losing words.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import unicodedata
from collections import defaultdict
from pathlib import Path

import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

DEFAULT_DIR = Path(os.environ.get("VOCA_ASR_BENCH_DIR") or Path.home() / ".cache/vocaphone/asr-bench")
ENGLISH = EnglishTextNormalizer()


def normalise(text: str, language: str) -> str:
    if language == "en":
        return ENGLISH(text)
    text = unicodedata.normalize("NFC", text).lower()
    # Drop punctuation and symbols, keep letters, digits and combining marks.
    text = "".join(" " if unicodedata.category(c)[0] in "PSZ" else c for c in text)
    return re.sub(r"\s+", " ", text).strip()


def load_jsonl(path: Path) -> list[dict]:
    """Every complete record. A last line cut short by an interrupted run is
    skipped; the runner trims it before it resumes."""
    lines = [line for line in path.read_text().splitlines() if line.strip()]
    records = []
    for index, line in enumerate(lines):
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            if index != len(lines) - 1:
                raise
    return records


def score(results: Path, manifest: Path, only: set[str] | None = None) -> dict | None:
    references = {clip["id"]: clip for clip in load_jsonl(manifest)}
    hypotheses = [h for h in load_jsonl(results) if h["id"] in references and (only is None or h["id"] in only)]
    if not hypotheses:
        return None
    language = references[hypotheses[0]["id"]]["language"]
    row: dict = {"clips": len(hypotheses), "language": language}
    refs = [normalise(references[h["id"]]["text"], language) for h in hypotheses]
    for field in ("raw", "finished"):
        hyps = [normalise(h[field], language) for h in hypotheses]
        # jiwer refuses an empty reference; no clip has one, but guard anyway.
        pairs = [(r, h) for r, h in zip(refs, hyps) if r]
        output = jiwer.process_words([r for r, _ in pairs], [h for _, h in pairs])
        row[f"{field}_wer"] = output.wer * 100
        row[f"{field}_sub"] = output.substitutions
        row[f"{field}_del"] = output.deletions
        row[f"{field}_ins"] = output.insertions
        if language != "en":
            row[f"{field}_cer"] = jiwer.cer([r for r, _ in pairs], [h for _, h in pairs]) * 100
    row["empty"] = sum(1 for h in hypotheses if not h["raw"].strip())
    row["empty_windows"] = sum(h.get("emptyWindows", 0) for h in hypotheses)
    audio = sum(references[h["id"]]["seconds"] for h in hypotheses)
    row["rtf"] = sum(h["milliseconds"] for h in hypotheses) / 1000 / audio if audio else 0
    return row


def collect(root: Path, tag: str) -> dict[tuple[str, str, str], dict]:
    table = {}
    for results in sorted((root / "results" / tag).glob("*/*.jsonl")):
        model = results.parent.name
        set_name, path = results.name.removesuffix(".jsonl").rsplit(".", 1)
        row = score(results, root / "sets" / set_name / "manifest.jsonl")
        if row:
            table[(model, set_name, path)] = row
    return table


def print_table(tag: str, table: dict) -> None:
    print(f"\n### {tag}\n")
    print("| Model | Set | Path | Clips | WER raw | WER finished | CER finished | Sub / Del / Ins (finished) | Empty | RTF |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for (model, set_name, path), row in sorted(table.items()):
        cer = f"{row['finished_cer']:.2f}" if "finished_cer" in row else ""
        print(
            f"| {model} | {set_name} | {path} | {row['clips']} | {row['raw_wer']:.2f} | "
            f"{row['finished_wer']:.2f} | {cer} | "
            f"{row['finished_sub']} / {row['finished_del']} / {row['finished_ins']} | "
            f"{row['empty']} | {row['rtf']:.3f} |"
        )


def clip_ids(path: Path) -> set[str]:
    return {record["id"] for record in load_jsonl(path)}


def print_comparison(root: Path, base_tag: str, new_tag: str) -> None:
    """Both runs scored on the clips both decoded, so a limited or unfinished
    run cannot look better for having heard easier speech."""
    print(f"\n### {base_tag} vs {new_tag} (WER finished, shared clips only)\n")
    print(f"| Model | Set | Path | Clips | {base_tag} | {new_tag} | Change |")
    print("|---|---|---|---|---|---|---|")
    base_files = {p.relative_to(root / "results" / base_tag) for p in (root / "results" / base_tag).glob("*/*.jsonl")}
    new_files = {p.relative_to(root / "results" / new_tag) for p in (root / "results" / new_tag).glob("*/*.jsonl")}
    for relative in sorted(base_files & new_files):
        model = relative.parent.name
        set_name, path = relative.name.removesuffix(".jsonl").rsplit(".", 1)
        base_path, new_path = root / "results" / base_tag / relative, root / "results" / new_tag / relative
        shared = clip_ids(base_path) & clip_ids(new_path)
        manifest = root / "sets" / set_name / "manifest.jsonl"
        before, after = score(base_path, manifest, shared), score(new_path, manifest, shared)
        if not before or not after:
            continue
        b, a = before["finished_wer"], after["finished_wer"]
        print(f"| {model} | {set_name} | {path} | {len(shared)} | {b:.2f} | {a:.2f} | {a - b:+.2f} |")


def worst(root: Path, tag: str, model: str, set_name: str, path: str, count: int) -> None:
    """The clips with the most errors, for reading what went wrong."""
    references = {c["id"]: c for c in load_jsonl(root / "sets" / set_name / "manifest.jsonl")}
    rows = []
    for h in load_jsonl(root / "results" / tag / model / f"{set_name}.{path}.jsonl"):
        clip = references[h["id"]]
        ref, hyp = normalise(clip["text"], clip["language"]), normalise(h["finished"], clip["language"])
        errors = jiwer.process_words(ref, hyp)
        rows.append((errors.substitutions + errors.deletions + errors.insertions, h["id"], ref, hyp, h["raw"]))
    for count_errors, clip_id, ref, hyp, raw in sorted(rows, reverse=True)[:count]:
        print(f"\n{clip_id}: {count_errors} errors\n  ref: {ref}\n  hyp: {hyp}\n  raw: {raw}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", type=Path, default=DEFAULT_DIR)
    parser.add_argument("--tag", help="one run (default: every run)")
    parser.add_argument("--compare", metavar="TAG", help="a second run to compare --tag against")
    parser.add_argument("--worst", nargs=3, metavar=("MODEL", "SET", "PATH"), help="print the worst clips of one result")
    parser.add_argument("--count", type=int, default=10)
    args = parser.parse_args()

    if args.worst:
        worst(args.dir, args.tag or "current", *args.worst, args.count)
        return
    tags = [args.tag] if args.tag else sorted(p.name for p in (args.dir / "results").iterdir() if p.is_dir())
    tables = {tag: collect(args.dir, tag) for tag in tags}
    if args.compare:
        tables[args.compare] = collect(args.dir, args.compare)
    for tag, table in tables.items():
        print_table(tag, table)
    if args.tag and args.compare:
        print_comparison(args.dir, args.tag, args.compare)


if __name__ == "__main__":
    main()
