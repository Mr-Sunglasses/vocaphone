#!/usr/bin/env python3
"""Downloads the pinned Universal Dependencies English Web Treebank files.

    python3 fetch.py [DIR]     # default ~/.cache/vocaphone/ud-english-ewt

The treebank (CC BY-SA 4.0) is what `train.py` learns Writing check's tagger
from. Pinned to one commit, each file checked by size and SHA-256.
"""

from __future__ import annotations

import hashlib
import sys
import urllib.request
from pathlib import Path

COMMIT = "4a4d77f599ea53cc405f85d0cec4b2f14f81d42b"
BASE = f"https://raw.githubusercontent.com/UniversalDependencies/UD_English-EWT/{COMMIT}/"
FILES = {
    "en_ewt-ud-train.conllu": "d68e06122a702464c613076523d56740f047e5bbe89dd90ec32737e04d952143",
    "en_ewt-ud-dev.conllu": "39239e0a60db3ae68f4b7036189f11b6692741d10ff8240dd91f74f2760d90f8",
    "en_ewt-ud-test.conllu": "fa024f43dc5da3c5ac02563bc9bd0e974f46cbb1560823976a8f342a37dc494a",
}


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / ".cache" / "vocaphone" / "ud-english-ewt"
    out.mkdir(parents=True, exist_ok=True)
    for name, digest in FILES.items():
        path = out / name
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            with urllib.request.urlopen(BASE + name, timeout=120) as r:
                path.write_bytes(r.read())
        got = hashlib.sha256(path.read_bytes()).hexdigest()
        if got != digest:
            sys.exit(f"{name}: SHA-256 {got}, expected {digest}")
        print(f"{name}: ok")
    print(out)


if __name__ == "__main__":
    main()
