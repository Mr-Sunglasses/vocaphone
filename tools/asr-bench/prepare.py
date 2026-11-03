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
| `vocab-en` | `vocab_en.json`, spoken by macOS `say` in six English voices | Names, product names and jargon, with the Dictionary a user would have entered |

    tools/asr-bench/prepare.py                       # every set, default sizes
    tools/asr-bench/prepare.py --sets librispeech-long --long-limit 40
    tools/asr-bench/prepare.py --sets vocab-en       # macOS only

Writes `<out>/sets/<set>/manifest.jsonl`, one line per clip with its file,
length, language and reference text; `vocab-en` clips also carry the
`vocabulary` the runners hand the app and the `terms` the score expects to see
spelled. Nothing here is checked in: AGENTS.md keeps recordings and transcripts
out of the repository.

Needs `ffmpeg` (LibriSpeech is FLAC), and `say` and `afconvert` for `vocab-en`.
Without those two (any host but a Mac), a bare run skips `vocab-en`.
Standard library only otherwise.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import platform
import re
import tarfile
import tempfile
from collections import defaultdict
from pathlib import Path

import vocab

RATE = 16_000
DEFAULT_OUT = Path(os.environ.get("VOCA_ASR_BENCH_DIR") or Path.home() / ".cache/vocaphone/asr-bench")

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

SETS = ("librispeech-clean", "librispeech-other", "librispeech-long", "fleurs-hi", "vocab-en")

# The vocab-en script is checked in, so it is pinned like a download: an edit
# changes what every earlier vocab-en result measured, and has to be a
# deliberate one that updates this digest (and deletes the old set).
VOCAB_SPEC = Path(__file__).resolve().with_name("vocab_en.json")
VOCAB_SPEC_SHA256 = "537771ed468584d0cae443bc6aa4c7974c865a20664009e79b5a18f57857b881"
# Stock macOS voices, one per English accent `say` ships, taken in turn.
VOCAB_VOICES = ("Samantha", "Daniel", "Karen", "Moira", "Rishi", "Tessa")
# Dictionary terms the sentence does not use, beside the ones it does.
VOCAB_DISTRACTORS = 4
# Room tone either side, as a dictation has between the tap and the first word.
VOCAB_PADDING_SECONDS = 0.3

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
    if count <= 0:
        return []
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


def chapters_of(audio: dict[str, bytes]) -> list[list[str]]:
    """Each chapter's utterance ids, in reading order, chapters sorted."""
    grouped: dict[str, list[str]] = defaultdict(list)
    for key in audio:
        speaker, chapter, _ = key.split("-")
        grouped[f"{speaker}-{chapter}"].append(key)
    return [
        sorted(grouped[chapter], key=utterance_order)
        for chapter in sorted(grouped, key=lambda c: tuple(map(int, c.split("-"))))
    ]


def pick_long(sources: list[list[list[str]]], limit: int, make_clip) -> list[dict]:
    """`limit` clips shared evenly between the sources, `make_clip(source,
    chapter)` building one or returning None for a chapter too short.

    Each source gets its own quota. Drawing from all chapters at once took
    the first clips that worked, and test-clean's chapters come first, so the
    set came out entirely clean.
    """
    clips = []
    for index, chapters in enumerate(sources):
        quota = limit // len(sources) + (1 if index < limit % len(sources) else 0)
        preferred = evenly(chapters, quota * 2)
        candidates = preferred + [chapter for chapter in chapters if chapter not in preferred]
        taken = 0
        for chapter in candidates:
            if taken == quota:
                break
            clip = make_clip(index, chapter)
            if clip is not None:
                clips.append(clip)
                taken += 1
    return clips


def long_set(out: Path, sources: list[tuple[dict[str, bytes], dict[str, str]]], limit: int) -> None:
    gap = [0.0] * int(LONG_GAP_SECONDS * RATE)

    def make_clip(index: int, chapter: list[str]) -> dict | None:
        audio, text = sources[index]
        samples: list[float] = []
        words: list[str] = []
        for key in chapter:
            utterance = decode_flac(audio[key])
            if (len(samples) + len(gap) + len(utterance)) / RATE > LONG_MAX_SECONDS:
                break
            if samples:
                samples += gap
            samples += utterance
            words.append(text[key])
        if len(samples) / RATE < LONG_MIN_SECONDS:
            return None
        file = f"{chapter[0]}-long.wav"
        write_wav(out / "sets" / "librispeech-long" / file, samples)
        return {"id": f"{chapter[0]}-long", "file": file, "seconds": round(len(samples) / RATE, 3), "language": "en", "text": " ".join(words)}

    write_set(out, "librispeech-long", pick_long([chapters_of(audio) for audio, _ in sources], limit, make_clip))


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


def vocab_spec() -> dict:
    data = VOCAB_SPEC.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != VOCAB_SPEC_SHA256:
        sys.exit(
            f"{VOCAB_SPEC.name}: SHA-256 {actual}, expected {VOCAB_SPEC_SHA256}. "
            "If the edit is deliberate, update VOCAB_SPEC_SHA256 and delete sets/vocab-en."
        )
    return json.loads(data)


def say_voices() -> set[str]:
    listing = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, check=True).stdout
    return {match.group(1) for match in re.finditer(r"^(\w+)", listing, re.MULTILINE)}


def synthesize(text: str, voice: str, workdir: Path) -> list[float]:
    """`text` in `voice`, as 16 kHz mono float32 samples."""
    aiff, wav = workdir / "speech.aiff", workdir / "speech.wav"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEF32@{RATE}", "-c", "1", str(aiff), str(wav)], check=True)
    return decode_flac(wav.read_bytes())


def vocab_set(out: Path) -> None:
    if not shutil.which("say") or not shutil.which("afconvert"):
        sys.exit("vocab-en is spoken by macOS `say`; build it on a Mac.")
    spec = vocab_spec()
    missing = [voice for voice in VOCAB_VOICES if voice not in say_voices()]
    if missing:
        sys.exit(f"vocab-en: macOS has no {', '.join(missing)} voice; install it in System Settings > Accessibility > Spoken Content.")
    dictionary = [entry["term"] for entry in spec["terms"]]
    forms = {entry["term"]: entry["spoken"] for entry in spec["terms"] if "spoken" in entry}
    padding = [0.0] * int(VOCAB_PADDING_SECONDS * RATE)
    clips, digests = [], {}
    with tempfile.TemporaryDirectory() as directory:
        for index, sentence in enumerate(spec["sentences"]):
            clip_id = f"vocab-{index + 1:03d}"
            voice = VOCAB_VOICES[index % len(VOCAB_VOICES)]
            terms = vocab.expected_terms(sentence, dictionary)
            if not terms:
                sys.exit(f"vocab-en: {sentence!r} uses no Dictionary term")
            samples = padding + synthesize(vocab.spoken(sentence, forms), voice, Path(directory)) + padding
            file = f"{clip_id}.wav"
            path = out / "sets" / "vocab-en" / file
            write_wav(path, samples)
            digests[clip_id] = sha256(path)
            clips.append({
                "id": clip_id, "file": file, "seconds": round(len(samples) / RATE, 3), "language": "en",
                "text": sentence, "voice": voice, "terms": terms,
                "vocabulary": vocab.clip_vocabulary(clip_id, terms, dictionary, VOCAB_DISTRACTORS),
            })
    # `say` voices change between macOS releases, so two runs are only the
    # same audio when this file is the same.
    source = {
        "spec_sha256": VOCAB_SPEC_SHA256,
        "macos": f"{platform.mac_ver()[0]}",
        "voices": list(VOCAB_VOICES),
        "audio_sha256": digests,
    }
    (out / "sets" / "vocab-en" / "source.json").write_text(json.dumps(source, indent=2) + "\n")
    write_set(out, "vocab-en", clips)


def default_sets(has_tool=shutil.which) -> list[str]:
    """Every set this host can build: `vocab-en` needs macOS `say` and
    `afconvert`, so a bare run elsewhere prepares the others instead of
    failing after them. Asking for `--sets vocab-en` still names the tools."""
    speaks = bool(has_tool("say")) and bool(has_tool("afconvert"))
    return [name for name in SETS if name != "vocab-en" or speaks]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--sets", nargs="+", choices=SETS, default=default_sets())
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
    if "vocab-en" in args.sets:
        vocab_set(args.out)


if __name__ == "__main__":
    main()
