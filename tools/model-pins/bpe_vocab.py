#!/usr/bin/env python3
"""Build the BPE vocabulary a sherpa-onnx NeMo transducer needs for hotwords.

sherpa-onnx 1.13.8 biases a transducer toward the user's words only with
`modified_beam_search`, `modeling_unit = "bpe"` and a `bpe_vocab` file: it
splits each hotword into the model's own word pieces with that file and boosts
those piece sequences while it searches. The pinned sherpa-onnx exports carry
the token table (`tokens.txt`) but not the vocabulary, which keeps each piece's
merge score. The apps bundle it instead, one file per model, at
`assets/speech/<model id>.bpe.vocab`.

The file is derived, not written: it is the SentencePiece tokenizer inside
NVIDIA's own `.nemo` checkpoint, one `piece<TAB>score` line per piece in id
order. The checkpoint is a plain tar, so only the tokenizer member is fetched,
with HTTP range requests, rather than the whole 2.4 GB. Its digest is pinned
below, and the result has to rebuild the pinned `tokens.txt` byte for byte
before it is written: same pieces, same order, then the blank.

    tools/model-pins/bpe_vocab.py parakeet-unified-0.6b-en          # write it
    tools/model-pins/bpe_vocab.py parakeet-unified-0.6b-en --check  # compare

Standard library only (the tokenizer is a small protobuf, read by hand), so it
needs no package beyond Python 3. It needs the network; the offline check that
a bundled vocabulary still matches its model is in `check_catalogs.py`.

Provenance and license of each source are recorded in `SOURCES`. The
vocabulary is a list of the model's word pieces and carries that model's
license.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import ssl
import struct
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHERPA_PINS = ROOT / "ios/VocaPhoneApp/Models/sherpa_model_pins.json"
OUT = ROOT / "assets/speech"

SOURCES = {
    # NVIDIA Open Model License:
    # https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/
    "parakeet-unified-0.6b-en": {
        "repository": "nvidia/parakeet-unified-en-0.6b",
        "revision": "fe53cd885760c96b6a5f51a0bfd362cb4584a98b",
        "checkpoint": "parakeet-unified-en-0.6b.nemo",
        "tokenizer_suffix": "_tokenizer.model",
        "tokenizer_sha256": "07d4e5a63840a53ab2d4d106d2874768143fb3fbdd47938b3910d2da05bfb0a9",
        "license": "NVIDIA Open Model License",
    },
}


def path_for(model_id: str) -> Path:
    return OUT / f"{model_id}.bpe.vocab"


_OPENER = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl.create_default_context()))


def _range(url: str, start: int, length: int) -> bytes:
    if not url.startswith("https://huggingface.co/"):
        raise SystemExit(f"refusing to fetch {url}")
    request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{start + length - 1}"})
    with _OPENER.open(request, timeout=60) as response:
        data = response.read()
    if len(data) != length:
        raise SystemExit(f"short read at {start}: wanted {length} bytes, got {len(data)}")
    return data


def fetch_tar_member(url: str, suffix: str) -> bytes:
    """The first member of the remote tar at `url` whose name ends in `suffix`."""
    offset = 0
    while True:
        header = _range(url, offset, 512)
        if not header.strip(b"\0"):
            raise SystemExit(f"no member ending in {suffix} in {url}")
        name = header[0:100].rstrip(b"\0").decode()
        prefix = header[345:500].rstrip(b"\0").decode()
        if prefix:
            name = f"{prefix}/{name}"
        size = int(header[124:136].rstrip(b"\0 ") or b"0", 8)
        if name.endswith(suffix) and size > 0:
            return _range(url, offset + 512, size)
        offset += 512 + (size + 511) // 512 * 512


def _varint(data: bytes, at: int) -> tuple[int, int]:
    value = shift = 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, at
        shift += 7


def _fields(data: bytes):
    """(field number, wire type, value) for every field of one protobuf message."""
    at = 0
    while at < len(data):
        key, at = _varint(data, at)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, at = _varint(data, at)
        elif wire == 1:
            value, at = data[at:at + 8], at + 8
        elif wire == 2:
            length, at = _varint(data, at)
            value, at = data[at:at + length], at + length
        elif wire == 5:
            value, at = data[at:at + 4], at + 4
        else:
            raise SystemExit(f"unexpected protobuf wire type {wire}")
        yield number, wire, value


def pieces(model: bytes) -> list[tuple[str, float]]:
    """(piece, score) in id order from a SentencePiece `ModelProto`.

    `ModelProto.pieces` is field 1; each `SentencePiece` carries its text in
    field 1 and its score, a float, in field 2.
    """
    result = []
    for number, wire, value in _fields(model):
        if number != 1 or wire != 2:
            continue
        piece, score = "", 0.0
        for inner, inner_wire, inner_value in _fields(value):
            if inner == 1 and inner_wire == 2:
                piece = inner_value.decode("utf-8")
            elif inner == 2 and inner_wire == 5:
                (score,) = struct.unpack("<f", inner_value)
        result.append((piece, score))
    return result


def vocabulary(entries: list[tuple[str, float]]) -> str:
    """The `bpe_vocab` text sherpa-onnx reads: `piece<TAB>score` per line."""
    return "".join(f"{piece}\t{score!r}\n" for piece, score in entries)


def build(model_id: str) -> str:
    source = SOURCES[model_id]
    url = (
        f"https://huggingface.co/{source['repository']}/resolve/"
        f"{source['revision']}/{source['checkpoint']}"
    )
    tokenizer = fetch_tar_member(url, source["tokenizer_suffix"])
    digest = hashlib.sha256(tokenizer).hexdigest()
    if digest != source["tokenizer_sha256"]:
        raise SystemExit(f"{model_id}: tokenizer SHA-256 is {digest}, pinned {source['tokenizer_sha256']}")
    return vocabulary(pieces(tokenizer))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model", choices=sorted(SOURCES))
    parser.add_argument("--check", action="store_true", help="compare with the bundled file instead of writing it")
    args = parser.parse_args()

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from check_catalogs import check_bpe_vocab

    text = build(args.model)
    pin = json.loads(SHERPA_PINS.read_text())["models"][args.model]
    problems = check_bpe_vocab(args.model, text, pin)
    if problems:
        print("\n".join(problems))
        return 1
    target = path_for(args.model)
    if args.check:
        if not target.exists() or target.read_text(encoding="utf-8") != text:
            print(f"{target.relative_to(ROOT)} does not match {SOURCES[args.model]['repository']}")
            return 1
        print(f"OK: {target.relative_to(ROOT)} matches its source")
        return 0
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    print(f"wrote {target.relative_to(ROOT)} ({len(text.encode())} bytes, {text.count(chr(10))} pieces)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
