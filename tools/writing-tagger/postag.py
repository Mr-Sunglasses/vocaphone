"""Writing check's part-of-speech tagger: the reference both apps port.

A greedy averaged-perceptron tagger in the style of Honnibal's "A good
part-of-speech tagger in about 200 lines of Python", trained by `train.py` on
the Universal Dependencies English Web Treebank and shipped as
`assets/keyboard/en-pos.bin`. Kotlin (`PosTagger.kt`) and Swift
(`PosTagger.swift`) read the same file and must tag every sentence of
`assets/grammar/pos_fixtures.json` exactly as this does.

Everything that decides a tag is integer arithmetic so the three agree to the
bit: features are strings hashed with 64-bit FNV-1a over UTF-8, weights are
int16, a token's score for a tag is the sum of its features' weights, and the
highest score wins with ties going to the lower tag index.

Words are the tokens `WritingText.tokenize` makes (see ../grammar-eval/writing_text.py):
"don't" and "John's" are one token each, hyphens and slashes are tokens of
their own. A token whose treebank analysis is several words carries their tags
joined with "+": "don't" is VBP+RB, "it's" PRP+VBZ, "John's" NNP+POS.
"""

from __future__ import annotations

import struct
from bisect import bisect_left
from dataclasses import dataclass

MAGIC = b"VPOS"
VERSION = 1

START = ("-START-", "-START2-")
END = ("-END-", "-END2-")

_FNV_OFFSET = 0xCBF29CE484222325
_FNV_PRIME = 0x100000001B3
_MASK = 0xFFFFFFFFFFFFFFFF


def fnv(text: str) -> int:
    h = _FNV_OFFSET
    for b in text.encode("utf-8"):
        h ^= b
        h = (h * _FNV_PRIME) & _MASK
    return h


def normalize(word: str) -> str:
    """What the features see of a word: lowercase ASCII, numbers and foreign words collapsed."""
    w = word.replace("’", "'")
    if any(ord(c) > 127 for c in w):
        return "!FOREIGN"
    if w and all("0" <= c <= "9" for c in w):
        return "!YEAR" if len(w) == 4 else "!DIGITS"
    if w and "0" <= w[0] <= "9":
        return "!DIGITS"
    return w.lower()


def shape(word: str) -> str:
    """Capitalisation, which the lowercased features lose: X (all caps), Xx, x, d, p, f."""
    if any(ord(c) > 127 for c in word):
        return "f"
    first = word[0]
    if "0" <= first <= "9":
        return "d"
    if "A" <= first <= "Z":
        letters = [c for c in word if ("A" <= c <= "Z") or ("a" <= c <= "z")]
        return "X" if len(letters) > 1 and all("A" <= c <= "Z" for c in letters) else "Xx"
    if "a" <= first <= "z":
        return "x"
    return "p"


def suffix(w: str) -> str:
    return w[-3:]


def features(i: int, context: list[str], shapes: list[str], p1: str, p2: str) -> list[str]:
    """Feature strings for token i; `context` is the normalised words padded by two on each side."""
    w = context[i + 2]
    return [
        "b",
        "s " + suffix(w),
        "p " + w[0],
        "t1 " + p1,
        "t2 " + p2,
        "t12 " + p1 + " " + p2,
        "w " + w,
        "t1w " + p1 + " " + w,
        "w-1 " + context[i + 1],
        "s-1 " + suffix(context[i + 1]),
        "w-2 " + context[i],
        "w+1 " + context[i + 3],
        "s+1 " + suffix(context[i + 3]),
        "w+2 " + context[i + 4],
        "sh " + shapes[i],
    ]


def context_of(words: list[str]) -> list[str]:
    return [START[0], START[1]] + [normalize(w) for w in words] + [END[0], END[1]]


@dataclass
class Model:
    tags: list[str]
    tagdict: dict[int, int]          # fnv("w " + normalized word) → tag index
    hashes: list[int]                # sorted feature hashes
    offsets: list[int]               # len(hashes) + 1
    entries: list[tuple[int, int]]   # (tag index, weight) runs per feature

    def weights(self, h: int):
        i = bisect_left(self.hashes, h)
        if i < len(self.hashes) and self.hashes[i] == h:
            return self.entries[self.offsets[i]:self.offsets[i + 1]]
        return ()

    def tag(self, words: list[str]) -> list[str]:
        context = context_of(words)
        shapes = [shape(w) for w in words]
        p1, p2 = START
        out = []
        for i in range(len(words)):
            fixed = self.tagdict.get(fnv("w " + context[i + 2]))
            if fixed is not None:
                best = fixed
            else:
                scores = [0] * len(self.tags)
                for f in features(i, context, shapes, p1, p2):
                    for t, wt in self.weights(fnv(f)):
                        scores[t] += wt
                best = 0
                for t in range(1, len(scores)):
                    if scores[t] > scores[best]:
                        best = t
            tag = self.tags[best]
            out.append(tag)
            p2, p1 = p1, tag
        return out

    # ── file format, little-endian ──────────────────────────────────────
    #   "VPOS" u32 version
    #   u16 tag count, then each tag: u8 length + UTF-8 bytes
    #   u32 tagdict count, then u64 hashes (sorted), then u8 tag per entry
    #   u32 feature count, u64 hashes (sorted), u32 offsets (count + 1),
    #   then per entry u8 tag + i16 weight

    def to_bytes(self) -> bytes:
        out = bytearray(MAGIC)
        out += struct.pack("<I", VERSION)
        out += struct.pack("<H", len(self.tags))
        for t in self.tags:
            b = t.encode("utf-8")
            out += struct.pack("<B", len(b)) + b
        items = sorted(self.tagdict.items())
        out += struct.pack("<I", len(items))
        out += b"".join(struct.pack("<Q", h) for h, _ in items)
        out += bytes(t for _, t in items)
        out += struct.pack("<I", len(self.hashes))
        out += b"".join(struct.pack("<Q", h) for h in self.hashes)
        out += b"".join(struct.pack("<I", o) for o in self.offsets)
        out += b"".join(struct.pack("<Bh", t, w) for t, w in self.entries)
        return bytes(out)

    @staticmethod
    def from_bytes(data: bytes) -> "Model":
        assert data[:4] == MAGIC, "not a VPOS file"
        (version,) = struct.unpack_from("<I", data, 4)
        assert version == VERSION, version
        p = 8
        (n,) = struct.unpack_from("<H", data, p)
        p += 2
        tags = []
        for _ in range(n):
            ln = data[p]
            tags.append(data[p + 1:p + 1 + ln].decode("utf-8"))
            p += 1 + ln
        (n,) = struct.unpack_from("<I", data, p)
        p += 4
        keys = list(struct.unpack_from(f"<{n}Q", data, p))
        p += 8 * n
        vals = list(data[p:p + n])
        p += n
        tagdict = dict(zip(keys, vals))
        (n,) = struct.unpack_from("<I", data, p)
        p += 4
        hashes = list(struct.unpack_from(f"<{n}Q", data, p))
        p += 8 * n
        offsets = list(struct.unpack_from(f"<{n + 1}I", data, p))
        p += 4 * (n + 1)
        m = offsets[-1]
        entries = [struct.unpack_from("<Bh", data, p + 3 * k) for k in range(m)]
        p += 3 * m
        assert p == len(data), (p, len(data))
        return Model(tags, tagdict, hashes, offsets, entries)
