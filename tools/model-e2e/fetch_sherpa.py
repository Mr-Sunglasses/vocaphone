#!/usr/bin/env python3
"""Download one pinned sherpa-onnx model for the iOS model tests.

The repository, revision, files and digests come from the pins the app itself
verifies against (`ios/VocaPhoneApp/Models/sherpa_model_pins.json`). A file
already present with the right digest is not fetched again, so a CI cache of the
output directory is safe to reuse.

    tools/model-e2e/fetch_sherpa.py parakeet-tdt-ctc-110m-en ios/build/model-e2e

Writes `<out>/<model id>/...`, the layout `LocalModelManager` uses on the phone,
and prints the model directory.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from fetch_whisper import fetch

PINS = Path(__file__).resolve().parents[2] / "ios/VocaPhoneApp/Models/sherpa_model_pins.json"


def plan(model_id: str, out: Path) -> list[tuple[str, Path, int, str]]:
    """Every file one model needs, as (url, destination, size, sha256)."""
    models = json.loads(PINS.read_text())["models"]
    model = models.get(model_id)
    if model is None:
        sys.exit(f"{model_id} is not pinned in {PINS.name}: {', '.join(models)}")
    return [
        (
            f"https://huggingface.co/{model['repository']}/resolve/{model['revision']}/{file['path']}",
            out / model_id / file["path"],
            file["size"],
            file["sha256"],
        )
        for file in model["files"]
    ]


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
