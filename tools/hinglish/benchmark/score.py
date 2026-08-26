#!/usr/bin/env python3
"""Score a whisper.cpp model on the Roman Hinglish evaluation set.

    python3 tools/hinglish/benchmark/score.py \
        --model ~/models/ggml-apex-hinglish-q5_0.bin \
        --whisper-cli ~/whisper.cpp/build/bin/whisper-cli

Audio is not in the repository. Run `fetch.py` first; it downloads the clips
this manifest names from their upstream sources and checks their digests.

What is measured, and why each metric is here rather than just word error rate:

  wer / cer            How much of what was said came back, against the Roman
                       reference. Both are computed on *collapsed* spellings —
                       see `collapse` — because "mujhe" and "muje" are the same
                       word and counting them as an error measures the spelling
                       convention rather than the model.
  english_preservation Of the words genuinely spoken in English, how many came
                       back as English words. This is the metric a translation
                       model would fail and a Hindi model would fail, in
                       different directions, while both could post a fair WER.
  devanagari_leakage   Fraction of samples with any Devanagari in the output.
                       The one metric that must be zero after normalization: it
                       is the promise the mode makes.
  translation_rate     Fraction of samples that came back as English prose
                       rather than as romanized Hindi — the specific failure
                       where the model answers the meaning instead of the words.
  rtf                  Decode seconds per audio second, on this machine.
  ttft_ms              Wall time to the first transcript. Whisper is not
                       streaming, so for a short clip this is the whole decode;
                       it is reported separately because it is what a dictation
                       user actually waits for.
  peak_rss_mb          Peak resident memory of the decode process.

Results go to stdout as a table and, with --json, to a file that can be diffed
between runs.
"""

from __future__ import annotations

import argparse
import json
import re
import resource
import subprocess
import sys
import time
import unicodedata
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "manifest.json"
DEVANAGARI = re.compile(r"[ऀ-ॿ]")

# ---------------------------------------------------------------- normalizing


def collapse(word: str) -> str:
    """Fold the spellings of one romanized Hindi word onto a single key.

    Roman Hinglish has no orthography. "mujhe" and "muje", "kyun" and "kyon",
    "theek" and "thik" are the same word, and a scorer that calls four of those
    six errors is measuring a convention nobody agreed to. So scoring happens on
    a deliberately lossy key: long and short vowels merge, aspirates lose their
    h, doubled letters collapse, and the nasal endings unify.

    This is only ever applied on both sides at once, so it cannot flatter the
    model — it can only stop the metric punishing a spelling difference.
    """
    word = unicodedata.normalize("NFKC", word).lower()
    word = re.sub(r"[^a-z0-9]", "", word)
    if not word:
        return ""
    # Long vowels onto short.
    word = word.replace("aa", "a").replace("ee", "i").replace("oo", "u")
    word = word.replace("ii", "i").replace("uu", "u")
    # One spelling per sound where Roman Hinglish uses several.
    word = word.replace("chh", "ch").replace("sh", "s").replace("z", "j")
    word = word.replace("v", "w").replace("y", "i")
    # Aspiration is the most common spelling difference and the least
    # meaningful one in this script.
    word = re.sub(r"([kgcjtdpb])h", r"\1", word)
    # Doubled letters.
    word = re.sub(r"(.)\1+", r"\1", word)
    # Nasal endings: "hain", "hai", "hain'" all key the same.
    word = re.sub(r"[nm]$", "n", word)
    return word


def tokens(text: str) -> list[str]:
    return [t for t in (collapse(w) for w in re.findall(r"\S+", text)) if t]


def raw_words(text: str) -> list[str]:
    return re.findall(r"[^\s]+", text)


# -------------------------------------------------------------------- metrics


def edit_distance(a: list, b: list) -> int:
    if not a:
        return len(b)
    previous = list(range(len(b) + 1))
    for i, item_a in enumerate(a, start=1):
        current = [i]
        for j, item_b in enumerate(b, start=1):
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (item_a != item_b),
                )
            )
        previous = current
    return previous[-1]


def wer(reference: str, hypothesis: str) -> float:
    ref = tokens(reference)
    if not ref:
        return 0.0
    return edit_distance(ref, tokens(hypothesis)) / len(ref)


def cer(reference: str, hypothesis: str) -> float:
    ref = list("".join(tokens(reference)))
    if not ref:
        return 0.0
    return edit_distance(ref, list("".join(tokens(hypothesis)))) / len(ref)


def english_preservation(english_words: list[str], hypothesis: str) -> float | None:
    """Of the words genuinely spoken in English, how many survived as English.

    `None` when the sample has no English in it, so that Hindi-only clips do not
    silently score 100% and inflate the average.
    """
    if not english_words:
        return None
    present = {collapse(w) for w in raw_words(hypothesis)}
    kept = sum(1 for w in english_words if collapse(w) in present)
    return kept / len(english_words)


def looks_translated(reference: str, hypothesis: str, english_words: list[str]) -> bool:
    """Whether the model answered the meaning instead of the words.

    The signature of a translation is that the Hindi half is gone: the English
    words survive (they were English already) while almost none of the romanized
    Hindi words do. Judged on the Hindi half alone, with a deliberately low bar,
    because this is a "did the model do the wrong task" flag rather than a
    quality score.
    """
    english = {collapse(w) for w in english_words}
    hindi = [t for t in tokens(reference) if t not in english]
    if len(hindi) < 3:
        return False
    present = set(tokens(hypothesis))
    matched = sum(1 for t in hindi if t in present)
    return matched / len(hindi) < 0.25


def audio_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as handle:
        return handle.getnframes() / float(handle.getframerate())


# ------------------------------------------------------------------- decoding


def decode(cli: Path, model: Path, audio: Path, language: str) -> tuple[str, float, int]:
    """Runs one decode and reports the text, wall seconds and peak RSS in bytes."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    started = time.perf_counter()
    result = subprocess.run(
        [
            str(cli),
            "--model", str(model),
            "--file", str(audio),
            "--language", language,
            "--no-timestamps",
            "--no-prints",
            "--output-txt", "--output-file", "-",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed = time.perf_counter() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    if result.returncode != 0:
        raise RuntimeError(f"{audio.name}: whisper-cli exited {result.returncode}\n{result.stderr}")
    # macOS reports ru_maxrss in bytes, Linux in kilobytes.
    scale = 1 if sys.platform == "darwin" else 1024
    return result.stdout.strip(), elapsed, max(after - before, after) * scale


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, type=Path, help="ggml model file")
    parser.add_argument("--whisper-cli", required=True, type=Path)
    parser.add_argument("--audio-dir", type=Path, default=HERE / "audio")
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    parser.add_argument(
        "--language",
        default="hi",
        help="decoder token. The app maps hinglish_roman to hi; pass the same here.",
    )
    parser.add_argument(
        "--normalize",
        action="store_true",
        help="apply the app's normalization layer before scoring (needs normalize.py)",
    )
    parser.add_argument("--json", type=Path, help="write the full per-sample results here")
    parser.add_argument("--category", help="score only this category")
    parser.add_argument(
        "--trust-model-card",
        action="store_true",
        help="include the clips whose reference is the Apex model card's own "
             "published output in WER and CER. Off by default: scoring a model "
             "against its own output measures nothing. Turn it on only when the "
             "model under test is not Apex.",
    )
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text())
    # The two tiers are scored as one list; `reference_provenance` is what keeps
    # them distinguishable in the output and in the WER rule below.
    samples = manifest["samples"] + manifest.get("prompts", [])
    if args.category:
        samples = [s for s in samples if s["category"] == args.category]
    samples = [s for s in samples if (args.audio_dir / s["file"]).exists()]
    if not samples:
        print(
            "no audio found — run fetch.py for the public clips and record.py "
            "for the read-aloud prompts",
            file=sys.stderr,
        )
        return 2

    normalize = (lambda text: text)
    if args.normalize:
        sys.path.insert(0, str(HERE))
        from normalize import normalize as normalize_text  # noqa: PLC0415

        normalize = normalize_text

    rows = []
    for sample in samples:
        audio = args.audio_dir / sample["file"]
        text, elapsed, peak = decode(args.whisper_cli, args.model, audio, args.language)
        text = normalize(text)
        english = sample.get("english_words", [])
        reference = sample.get("reference")
        provenance = sample.get("reference_provenance", "unlabelled")
        # Only a reference that was not produced by the model under test can
        # support an error rate. An unlabelled clip has none at all, and a
        # model-card reference is Apex's own output — useful for comparing some
        # other model against it, worthless for scoring Apex.
        scorable = reference is not None and (
            provenance != "model-card" or args.trust_model_card
        )
        rows.append(
            {
                "id": sample["id"],
                "category": sample["category"],
                "provenance": provenance,
                "reference": reference,
                "hypothesis": text,
                "wer": wer(reference, text) if scorable else None,
                "cer": cer(reference, text) if scorable else None,
                "english_preservation": (
                    english_preservation(english, text) if scorable else None
                ),
                "devanagari_leak": bool(DEVANAGARI.search(text)),
                "translated": (
                    looks_translated(reference, text, english) if scorable else None
                ),
                "seconds": elapsed,
                "audio_seconds": audio_seconds(audio),
                "peak_rss_mb": peak / 1_000_000,
            }
        )

    def mean(key, rows=rows):
        values = [r[key] for r in rows if r[key] is not None]
        return sum(values) / len(values) if values else float("nan")

    def rate(key, rows=rows):
        judged = [r for r in rows if r[key] is not None]
        return sum(bool(r[key]) for r in judged) / len(judged) if judged else float("nan")

    scored = [r for r in rows if r["wer"] is not None]
    summary = {
        "model": args.model.name,
        "model_bytes": args.model.stat().st_size,
        "samples": len(rows),
        # Said out loud, because "WER 0.21 over 51 samples" would be a lie when
        # only 40 of them carry a reference this model can be scored against.
        "scored_against_a_reference": len(scored),
        "wer": mean("wer"),
        "cer": mean("cer"),
        "english_preservation": mean("english_preservation"),
        # Leakage is the one metric every clip can support: it needs no
        # reference, only the output.
        "devanagari_leakage": sum(r["devanagari_leak"] for r in rows) / len(rows),
        "translation_rate": rate("translated"),
        "rtf": sum(r["seconds"] for r in rows) / sum(r["audio_seconds"] for r in rows),
        "ttft_ms": mean("seconds") * 1000,
        "peak_rss_mb": max(r["peak_rss_mb"] for r in rows),
    }

    print(f"{'category':<28} {'n':>3} {'WER':>7} {'CER':>7} {'EN':>7} {'deva':>6} {'trans':>6}")
    categories = sorted({r["category"] for r in rows})
    for category in categories:
        group = [r for r in rows if r["category"] == category]
        print(
            f"{category:<28} {len(group):>3} "
            f"{mean('wer', group):>7.3f} {mean('cer', group):>7.3f} "
            f"{mean('english_preservation', group):>7.3f} "
            f"{sum(r['devanagari_leak'] for r in group) / len(group):>6.2f} "
            f"{rate('translated', group):>6.2f}"
        )
    print()
    for key, value in summary.items():
        print(f"{key:<22} {value}")

    if args.json:
        args.json.write_text(json.dumps({"summary": summary, "samples": rows}, indent=2))
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
