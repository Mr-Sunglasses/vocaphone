#!/usr/bin/env python3
"""Download one pinned WhisperKit model, and its tokenizer, for the model tests.

The files and digests come from the pins the app itself verifies against
(`ios/VocaPhoneApp/Models/local_model_pins.json`). A test therefore runs the
exact bytes a phone would, and changing a pin changes what the tests download.
Each file is checked by SHA-256. A file already present with the right digest
is not downloaded again, so a CI cache of the output directory is safe to reuse.

    tools/model-e2e/fetch_whisper.py openai_whisper-small_216MB ios/build/model-e2e

Writes `<out>/<model id>/...` and `<out>/Tokenizers/<tokenizer name>/...`, the
same layout `LocalModelManager` uses on the phone, and prints the model
directory.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

PINS = Path(__file__).resolve().parents[2] / "ios/VocaPhoneApp/Models/local_model_pins.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


# Every pinned file is on Hugging Face, which answers with a redirect to its CDN.
ALLOWED_PREFIX = "https://huggingface.co/"


def fetch(url: str, destination: Path, size: int, expected: str) -> None:
    if not url.startswith(ALLOWED_PREFIX):
        sys.exit(f"Refusing to download from {url}: pinned models come only from {ALLOWED_PREFIX}")
    if destination.exists() and destination.stat().st_size == size and sha256(destination) == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    # curl rather than urllib, which also opens `file:` and `ftp:` URLs:
    # `--proto` allows HTTPS alone, and `--proto-redir` holds the CDN redirect
    # to the same, so nothing but an HTTPS server can answer.
    subprocess.run(
        [
            "curl", "--proto", "=https", "--proto-redir", "=https",
            "--fail", "--location", "--max-redirs", "5", "--retry", "3",
            "--silent", "--show-error", "--output", str(partial), url,
        ],
        check=True,
    )
    # Whatever answered, only the pinned bytes are kept.
    actual = sha256(partial)
    if actual != expected:
        partial.unlink()
        sys.exit(f"{destination}: SHA-256 {actual} does not match the pin {expected}")
    partial.replace(destination)


def tokenizer_for(model_id: str, tokenizers: dict) -> str:
    # `openai_whisper-small_216MB` pins against `openai/whisper-small`.
    candidate = model_id.replace("_", "/", 1)
    matches = [name for name in tokenizers if candidate.startswith(name)]
    if not matches:
        sys.exit(f"No pinned tokenizer for {model_id}")
    return max(matches, key=len)


def plan(model_id: str, out: Path) -> list[tuple[str, Path, int, str]]:
    """Every file one model needs, as (url, destination, size, sha256)."""
    pins = json.loads(PINS.read_text())
    model = pins["models"].get(model_id)
    if model is None:
        sys.exit(f"{model_id} is not pinned in {PINS.name}: {', '.join(pins['models'])}")

    repository, revision = pins["repository"], pins["revision"]
    files = [
        (
            f"https://huggingface.co/{repository}/resolve/{revision}/{model_id}/{file['path']}",
            out / model_id / file["path"],
            file["size"],
            file["sha256"],
        )
        for file in model["files"]
    ]
    tokenizer = tokenizer_for(model_id, pins["tokenizers"])
    pinned = pins["tokenizers"][tokenizer]
    files += [
        (
            f"https://huggingface.co/{tokenizer}/resolve/{pinned['revision']}/{file['path']}",
            # As `LocalModelManager.tokenizerFolderName` names it on the phone.
            out / "Tokenizers" / tokenizer.replace("/", "_") / file["path"],
            file["size"],
            file["sha256"],
        )
        for file in pinned["files"]
    ]
    return files


def all_plans(out: Path) -> list[tuple[str, Path, int, str]]:
    """Every pinned model's files; `selftest.py` checks them offline."""
    return [entry for model_id in json.loads(PINS.read_text())["models"] for entry in plan(model_id, out)]


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    model_id, out = sys.argv[1], Path(sys.argv[2])
    for entry in plan(model_id, out):
        fetch(*entry)
    print(out / model_id)


if __name__ == "__main__":
    main()
