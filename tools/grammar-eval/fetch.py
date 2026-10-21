#!/usr/bin/env python3
"""Downloads the five pinned tagger files and checks their SHA-256.

    python3 fetch.py [DEST]   # default: ~/.cache/vocaphone/mindtype-tagger-v1.5
"""

from __future__ import annotations

import hashlib
import sys
import urllib.request
from pathlib import Path

REPOSITORY = "Mindscend/mindtype-tagger-v1.5"
REVISION = "a737fbc7f563104d3d07cfeb198077950e223101"
PINS = {
    "onnx/mindtype_tagger.onnx": (26_700_289, "f082574ef27d3d0e2929ef321ab7490c08002fc6475ea7d9edbe7e534777319b"),
    "onnx/tokenizer.json": (1_113_060, "7430be0917758ae85b0322ed2686b9e14e7cb322e2cafa5f87f526544ccd829b"),
    "onnx/labels.json": (296_770, "62df98ed27d01c107c77690c73ec346c2a4a4e37cc850de5381a833589760891"),
    "onnx/plausible_pairs.json": (4_450, "201a30cd6fcc129070c0637b4566820c7cb4d77ef3969a7575af591a17e281f4"),
    "onnx/config.json": (149, "dde7552bfb73798ead6fbc9e14bb5b4aee062bf168b21341e69a16152a571241"),
}


def main() -> None:
    dest = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        Path.home() / ".cache" / "vocaphone" / "mindtype-tagger-v1.5"
    dest.mkdir(parents=True, exist_ok=True)
    for path, (size, digest) in PINS.items():
        target = dest / Path(path).name
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == digest:
            continue
        url = f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{path}"
        data = urllib.request.urlopen(url, timeout=120).read()
        got = hashlib.sha256(data).hexdigest()
        if len(data) != size or got != digest:
            sys.exit(f"{path}: expected {size} bytes {digest}, got {len(data)} bytes {got}")
        target.write_bytes(data)
    print(dest)


if __name__ == "__main__":
    main()
