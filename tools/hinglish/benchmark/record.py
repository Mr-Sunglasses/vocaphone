#!/usr/bin/env python3
"""Record the read-aloud half of the Roman Hinglish evaluation set.

    python3 tools/hinglish/benchmark/record.py

Prints one sentence at a time, records while you read it, and writes 16 kHz mono
WAV into a gitignored directory. Forty short sentences take about ten minutes.

This exists because the reference problem has no public answer: Roman-Hinglish
audio with an independent Roman transcript is not a corpus anyone publishes. A
sentence you read is its own reference, exactly, which is the only way to get a
trustworthy word error rate for this mode. See README.md.

Recording is your own voice into a local file. Nothing is uploaded, and the
audio directory is gitignored — do not commit it.

Needs ffmpeg with a microphone input (`avfoundation` on macOS, `alsa` on Linux).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def input_args(device: str | None) -> list[str]:
    if sys.platform == "darwin":
        return ["-f", "avfoundation", "-i", device or ":default"]
    return ["-f", "alsa", "-i", device or "default"]


def record(destination: Path, device: str | None) -> None:
    """Records until Enter. ffmpeg stops cleanly on `q` on its stdin."""
    process = subprocess.Popen(
        [
            "ffmpeg", "-loglevel", "error", "-y",
            *input_args(device),
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
            str(destination),
        ],
        stdin=subprocess.PIPE,
    )
    try:
        input()
    finally:
        if process.stdin:
            process.stdin.write(b"q")
            process.stdin.close()
        process.wait()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=HERE / "manifest.json")
    parser.add_argument("--out", type=Path, default=HERE / "audio")
    parser.add_argument(
        "--device",
        help="ffmpeg input device. macOS: ffmpeg -f avfoundation -list_devices true -i ''",
    )
    parser.add_argument("--category", help="record only this category")
    parser.add_argument(
        "--redo", action="store_true", help="re-record prompts that already have a file"
    )
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text())
    prompts = manifest["prompts"]
    if args.category:
        prompts = [p for p in prompts if p["category"] == args.category]
    args.out.mkdir(parents=True, exist_ok=True)

    pending = [p for p in prompts if args.redo or not (args.out / p["file"]).exists()]
    if not pending:
        print("every prompt is already recorded")
        return 0

    print(f"{len(pending)} to record. Enter starts, Enter stops. Ctrl-C quits.\n")
    for index, prompt in enumerate(pending, start=1):
        print(f"[{index}/{len(pending)}] {prompt['category']}")
        print(f"  {prompt['reference']}")
        try:
            input("  Enter to start... ")
            print("  recording — Enter to stop")
            record(args.out / prompt["file"], args.device)
        except KeyboardInterrupt:
            print("\nstopped; rerun to continue where you left off")
            return 0
        print()
    print(f"done — {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
