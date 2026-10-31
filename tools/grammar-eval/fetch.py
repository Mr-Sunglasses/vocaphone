#!/usr/bin/env python3
"""Downloads the five pinned tagger files and checks their SHA-256.

    python3 fetch.py [DEST]   # default: ~/.cache/vocaphone/mindtype-tagger-v2.0
"""

from __future__ import annotations

import hashlib
import ssl
import sys
import urllib.request
from pathlib import Path

REPOSITORY = "Mindscend/mindtype-tagger-v2.0"
REVISION = "e58cbb68c382a894a9f6de704fe385ec260f0949"
PINS = {
    "onnx/mindtype_tagger.onnx": (26_700_289, "cde26b40d62216c0b5680725b5e3f3b438f50cb6d02e05c395bf13059467da76"),
    "onnx/tokenizer.json": (1_113_060, "7430be0917758ae85b0322ed2686b9e14e7cb322e2cafa5f87f526544ccd829b"),
    "onnx/labels.json": (297_669, "1a8f56abf4ecf5adebf726c561c36c6f634309e2fca1857658df0ed22e504abd"),
    "onnx/plausible_pairs.json": (4_450, "201a30cd6fcc129070c0637b4566820c7cb4d77ef3969a7575af591a17e281f4"),
    "onnx/config.json": (149, "dde7552bfb73798ead6fbc9e14bb5b4aee062bf168b21341e69a16152a571241"),
}


def https_only() -> urllib.request.OpenerDirector:
    """An opener that can speak HTTPS and nothing else.

    urllib's default opener also opens file:// and plain http://, which a
    pinned download has no use for; without those handlers a URL, or a
    redirect, in any other scheme fails instead of being followed.
    ProxyHandler keeps what urlopen() gave for free: an https_proxy from the
    environment is still used, by tunnelling the HTTPS request through it.
    """
    opener = urllib.request.OpenerDirector()
    for handler in (
        urllib.request.ProxyHandler(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
        urllib.request.HTTPRedirectHandler(),
        urllib.request.HTTPErrorProcessor(),
        urllib.request.HTTPDefaultErrorHandler(),
    ):
        opener.add_handler(handler)
    return opener


def get(url: str) -> bytes:
    if not url.startswith("https://"):
        sys.exit(f"refusing to fetch {url}: only https is allowed")
    response = https_only().open(url, timeout=120)
    # No handler for the scheme: the opener answers None rather than raising.
    if response is None:
        sys.exit(f"refusing to fetch {url}: only https is allowed")
    with response:
        return response.read()


def main() -> None:
    dest = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        Path.home() / ".cache" / "vocaphone" / "mindtype-tagger-v2.0"
    dest.mkdir(parents=True, exist_ok=True)
    for path, (size, digest) in PINS.items():
        target = dest / Path(path).name
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == digest:
            continue
        # The pinned digest is checked before anything is written.
        data = get(f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{path}")
        got = hashlib.sha256(data).hexdigest()
        if len(data) != size or got != digest:
            sys.exit(f"{path}: expected {size} bytes {digest}, got {len(data)} bytes {got}")
        target.write_bytes(data)
    print(dest)


if __name__ == "__main__":
    main()
