#!/usr/bin/env python3
"""Download the Roman Hinglish evaluation clips this manifest names.

    python3 tools/hinglish/benchmark/fetch.py

No audio is committed to this repository — see AGENTS.md, "Do not commit
recordings or transcripts". Every clip here is fetched from a public source
under a licence that allows it, pinned by URL and SHA-256, and written into a
gitignored directory. Nothing private and nothing copyright-unclear is in the
manifest, and nothing should be added to it that is.

MP3 sources are converted to the 16 kHz mono WAV whisper.cpp reads, which needs
ffmpeg on PATH.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def to_wav(source: Path, destination: Path) -> None:
    """16 kHz mono PCM, which is the only thing whisper.cpp reads."""
    subprocess.run(
        [
            "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
            "-i", str(source),
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
            str(destination),
        ],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=HERE / "manifest.json")
    parser.add_argument("--out", type=Path, default=HERE / "audio")
    parser.add_argument(
        "--record-digests",
        action="store_true",
        help="write the digest of each freshly downloaded source back into the "
             "manifest. Use once when adding a sample; never on a normal fetch, "
             "which is meant to verify rather than to trust.",
    )
    args = parser.parse_args()

    if not shutil.which("ffmpeg"):
        print("ffmpeg is required to normalize the clips to 16 kHz mono", file=sys.stderr)
        return 2

    manifest = json.loads(args.manifest.read_text())
    args.out.mkdir(parents=True, exist_ok=True)
    cache = args.out / ".sources"
    cache.mkdir(exist_ok=True)

    changed = False
    for sample in manifest["samples"]:
        target = args.out / sample["file"]
        if target.exists():
            continue
        source = cache / Path(sample["url"]).name
        if not source.exists():
            print(f"fetching {sample['id']}")
            urllib.request.urlretrieve(sample["url"], source)  # noqa: S310

        digest = sha256(source)
        expected = sample.get("source_sha256")
        if args.record_digests and not expected:
            sample["source_sha256"] = digest
            changed = True
        elif expected and digest != expected:
            print(
                f"{sample['id']}: digest mismatch\n  expected {expected}\n  got      {digest}",
                file=sys.stderr,
            )
            return 1

        to_wav(source, target)

    if changed:
        args.manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
        print(f"updated {args.manifest}")

    print(f"{len(manifest['samples'])} clips ready in {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
