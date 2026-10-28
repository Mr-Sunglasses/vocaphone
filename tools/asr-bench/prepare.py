#!/usr/bin/env python3
"""Build the real-speech test sets the accuracy benchmark decodes.

Downloads public test sets into a cache outside the repository, checks each
archive's SHA-256, and writes a deterministic subset of each as the 16 kHz mono
float32 WAV the app captures:

| Set | Source | What it measures |
| --- | --- | --- |
| `librispeech-clean` | LibriSpeech test-clean | Read English, quiet |
| `librispeech-other` | LibriSpeech test-other | Read English, harder speakers |
| `librispeech-long` | Consecutive test-clean and test-other utterances from one chapter, joined into 45-90 s clips | Windowing and chunk seams, where both September 2026 bugs were |
| `fleurs-hi` | FLEURS Hindi test | Hindi in Devanagari |

    tools/asr-bench/prepare.py                       # every set, default sizes
    tools/asr-bench/prepare.py --sets librispeech-long --limit 40

Writes `<out>/sets/<set>/manifest.jsonl`, one line per clip with its file,
length, language and reference text. Nothing here is checked in: AGENTS.md
keeps recordings and transcripts out of the repository.

Needs `ffmpeg` (LibriSpeech is FLAC). Standard library only otherwise.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import struct
import subprocess
import sys
import tarfile
from collections import defaultdict
from pathlib import Path

RATE = 16_000
DEFAULT_OUT = Path.home() / ".cache/vocaphone/asr-bench"

# LibriSpeech and FLEURS are CC BY 4.0. The SHA-256 values were taken from
# complete downloads whose MD5 matched openslr's own `md5sum.txt`; FLEURS is
# pinned to a dataset commit on Hugging Face.
FLEURS_REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
ARCHIVES = {
    "test-clean.tar.gz": (
        "https://www.openslr.org/resources/12/test-clean.tar.gz",
        346_663_984,
        "39fde525e59672dc6d1551919b1478f724438a95aa55f874b576be21967e6c23",
    ),
    "test-other.tar.gz": (
        "https://www.openslr.org/resources/12/test-other.tar.gz",
        328_757_843,
        "d09c181bba5cf717b3dee7d4d592af11a3ee3a09e08ae025c5506f6ebe961c29",
    ),
    "fleurs-hi_in-test.tar.gz": (
        f"https://huggingface.co/datasets/google/fleurs/resolve/{FLEURS_REVISION}/data/hi_in/audio/test.tar.gz",
        249_331_325,
        "47c238b9cf7016ba596639bb3038b0c89dc6e85759f16d09c4f58c6dfa25c65f",
    ),
    "fleurs-hi_in-test.tsv": (
        f"https://huggingface.co/datasets/google/fleurs/resolve/{FLEURS_REVISION}/data/hi_in/test.tsv",
        473_366,
        "889e82e2875490f9533ff59ab67326fcfa01cf828fc4412758aaaa1f442a729f",
    ),
}

SETS = ("librispeech-clean", "librispeech-other", "librispeech-long", "fleurs-hi")

# Long-form clips: consecutive utterances of one chapter, with a short breath
# between them, until the clip is long enough to need several decode windows.
LONG_MIN_SECONDS = 45.0
LONG_MAX_SECONDS = 90.0
LONG_GAP_SECONDS = 0.3


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download(name: str, downloads: Path) -> Path:
    url, size, expected = ARCHIVES[name]
    path = downloads / name
    downloads.mkdir(parents=True, exist_ok=True)
    # openslr drops long transfers part way, so resume until the size is right.
    for _ in range(40):
        if path.exists() and path.stat().st_size >= size:
            break
        subprocess.run(
            [
                "curl", "--proto", "=https", "--proto-redir", "=https",
                "--location", "--silent", "--show-error", "--continue-at", "-",
                "--max-time", "300", "--output", str(path), url,
            ],
            check=False,
        )
    actual = sha256(path) if path.exists() else "missing"
    if actual != expected:
        sys.exit(f"{name}: SHA-256 {actual}, expected {expected}. Delete it and run again.")
    return path


def decode_flac(data: bytes) -> list[float]:
    """FLAC bytes as 16 kHz mono float32 samples, through ffmpeg."""
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", "pipe:0", "-ac", "1", "-ar", str(RATE), "-f", "f32le", "pipe:1"],
        input=data,
        capture_output=True,
        check=True,
    )
    count = len(result.stdout) // 4
    return list(struct.unpack(f"<{count}f", result.stdout[: count * 4]))


def read_wav_bytes(data: bytes) -> list[float]:
    """A 16 kHz mono WAV (FLEURS ships PCM16) as float32 samples, through ffmpeg."""
    return decode_flac(data)


def write_wav(path: Path, samples: list[float]) -> None:
    payload = struct.pack(f"<{len(samples)}f", *samples)
    header = b"RIFF" + struct.pack("<I", 36 + len(payload)) + b"WAVE"
    # Format 3 is IEEE float: one channel, 16 kHz, 4 bytes a sample.
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, RATE, RATE * 4, 4, 32)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + b"data" + struct.pack("<I", len(payload)) + payload)


def evenly(items: list, count: int) -> list:
    """`count` items spread across the sorted list, so every speaker is drawn
    from rather than the first few, and the same ones every run."""
    if count >= len(items):
        return list(items)
    step = len(items) / count
    return [items[int(index * step)] for index in range(count)]


def librispeech(archive: Path) -> tuple[dict[str, bytes], dict[str, str]]:
    """Every utterance's FLAC bytes and reference text, keyed by utterance id."""
    audio: dict[str, bytes] = {}
    text: dict[str, str] = {}
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            if not member.isfile():
                continue
            name = Path(member.name).name
            handle = tar.extractfile(member)
            if handle is None:
                continue
            if name.endswith(".flac"):
                audio[name.removesuffix(".flac")] = handle.read()
            elif name.endswith(".trans.txt"):
                for line in handle.read().decode().splitlines():
                    key, _, words = line.partition(" ")
                    text[key] = words
    return audio, text


def utterance_order(key: str) -> tuple[int, int, int]:
    speaker, chapter, index = key.split("-")
    return int(speaker), int(chapter), int(index)


def write_set(out: Path, name: str, clips: list[dict]) -> None:
    folder = out / "sets" / name
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "manifest.jsonl").open("w") as handle:
        for clip in clips:
            handle.write(json.dumps(clip, ensure_ascii=False) + "\n")
    seconds = sum(clip["seconds"] for clip in clips)
    print(f"{name}: {len(clips)} clips, {seconds / 60:.1f} min -> {folder}")


def short_set(out: Path, name: str, audio: dict[str, bytes], text: dict[str, str], limit: int) -> None:
    clips = []
    for key in evenly(sorted(audio, key=utterance_order), limit):
        samples = decode_flac(audio[key])
        file = f"{key}.wav"
        write_wav(out / "sets" / name / file, samples)
        clips.append({"id": key, "file": file, "seconds": round(len(samples) / RATE, 3), "language": "en", "text": text[key]})
    write_set(out, name, clips)


def long_set(out: Path, sources: list[tuple[dict[str, bytes], dict[str, str]]], limit: int) -> None:
    chapters: list[list[tuple[str, dict[str, bytes], dict[str, str]]]] = []
    for audio, text in sources:
        grouped: dict[str, list[str]] = defaultdict(list)
        for key in audio:
            speaker, chapter, _ = key.split("-")
            grouped[f"{speaker}-{chapter}"].append(key)
        for chapter in sorted(grouped, key=lambda c: tuple(map(int, c.split("-")))):
            chapters.append([(key, audio, text) for key in sorted(grouped[chapter], key=utterance_order)])

    gap = [0.0] * int(LONG_GAP_SECONDS * RATE)
    clips = []
    for chapter in evenly(chapters, limit * 2):
        if len(clips) == limit:
            break
        samples: list[float] = []
        words: list[str] = []
        first = chapter[0][0]
        for key, audio, text in chapter:
            utterance = decode_flac(audio[key])
            if (len(samples) + len(gap) + len(utterance)) / RATE > LONG_MAX_SECONDS:
                break
            if samples:
                samples += gap
            samples += utterance
            words.append(text[key])
        if len(samples) / RATE < LONG_MIN_SECONDS:
            continue
        file = f"{first}-long.wav"
        write_wav(out / "sets" / "librispeech-long" / file, samples)
        clips.append({"id": f"{first}-long", "file": file, "seconds": round(len(samples) / RATE, 3), "language": "en", "text": " ".join(words)})
    write_set(out, "librispeech-long", clips)


def fleurs_hindi(out: Path, downloads: Path, limit: int) -> None:
    rows = {}
    with (download("fleurs-hi_in-test.tsv", downloads)).open(newline="") as handle:
        for row in csv.reader(handle, delimiter="\t", quoting=csv.QUOTE_NONE):
            # id, file name, raw transcription, normalised transcription, ...
            rows[row[1]] = row[2]
    chosen = set(evenly(sorted(rows), limit))
    clips = []
    with tarfile.open(download("fleurs-hi_in-test.tar.gz", downloads), "r:gz") as tar:
        for member in tar:
            name = Path(member.name).name
            if name not in chosen or not member.isfile():
                continue
            handle = tar.extractfile(member)
            if handle is None:
                continue
            samples = read_wav_bytes(handle.read())
            key = name.removesuffix(".wav")
            write_wav(out / "sets" / "fleurs-hi" / name, samples)
            clips.append({"id": key, "file": name, "seconds": round(len(samples) / RATE, 3), "language": "hi", "text": rows[name]})
    clips.sort(key=lambda clip: clip["id"])
    write_set(out, "fleurs-hi", clips)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--sets", nargs="+", choices=SETS, default=list(SETS))
    parser.add_argument("--limit", type=int, default=200, help="clips per short set (default 200)")
    parser.add_argument("--long-limit", type=int, default=24, help="clips in librispeech-long (default 24)")
    args = parser.parse_args()

    downloads = args.out / "downloads"
    clean = other = None
    if {"librispeech-clean", "librispeech-long"} & set(args.sets):
        clean = librispeech(download("test-clean.tar.gz", downloads))
    if {"librispeech-other", "librispeech-long"} & set(args.sets):
        other = librispeech(download("test-other.tar.gz", downloads))

    if "librispeech-clean" in args.sets and clean:
        short_set(args.out, "librispeech-clean", *clean, args.limit)
    if "librispeech-other" in args.sets and other:
        short_set(args.out, "librispeech-other", *other, args.limit)
    if "librispeech-long" in args.sets and clean and other:
        long_set(args.out, [clean, other], args.long_limit)
    if "fleurs-hi" in args.sets:
        fleurs_hindi(args.out, downloads, args.limit)


if __name__ == "__main__":
    main()
