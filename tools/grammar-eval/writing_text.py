"""The word and sentence split Writing check uses, in Python.

A line-for-line mirror of `WritingText.tokenize` and `WritingText.sentences`
(android/.../writing/WritingText.kt, ios/VocaPhoneShared/Writing/WritingText.swift),
so `answers.py` asks the model exactly the sentences the apps ask it. Offsets
here are code points, not UTF-16 units; only the sentence strings leave this
file, and those are the same either way.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass

_WORD_CATEGORIES = {"Lu", "Ll", "Lt", "Lm", "Lo", "Nd", "Nl", "No"}
_TERMINALS = {".", "!", "?", "…"}
_CLOSERS = {'"', "'", "”", "’", ")", "]", "»"}
_LINE_BREAKS = {"\n", "\r", " ", " "}


@dataclass(frozen=True)
class Token:
    text: str
    start: int
    end: int
    is_word: bool


def _is_space(c: str) -> bool:
    cp = ord(c)
    return (0x09 <= cp <= 0x0D or 0x1C <= cp <= 0x20 or cp in (0x85, 0xA0, 0x1680)
            or 0x2000 <= cp <= 0x200A or cp in (0x2028, 0x2029, 0x202F, 0x205F, 0x3000))


def _is_word_char(c: str) -> bool:
    return unicodedata.category(c) in _WORD_CATEGORIES


def tokenize(text: str) -> list[Token]:
    out: list[Token] = []
    i = 0
    while i < len(text):
        c = text[i]
        if _is_space(c):
            i += 1
        elif _is_word_char(c):
            start = i
            i += 1
            while i < len(text):
                if _is_word_char(text[i]):
                    i += 1
                elif text[i] in "'’" and i + 1 < len(text) and _is_word_char(text[i + 1]):
                    i += 1
                else:
                    break
            out.append(Token(text[start:i], start, i, True))
        else:
            out.append(Token(c, i, i + 1, False))
            i += 1
    return out


def sentences(text: str) -> list[str]:
    """Each sentence's text, as `WritingCheck` hands it to the model."""
    tokens = tokenize(text)
    out: list[str] = []
    first = 0
    i = 0
    while i < len(tokens):
        last = i
        boundary = False
        if tokens[i].text in _TERMINALS:
            while (last + 1 < len(tokens) and tokens[last + 1].text in _CLOSERS
                   and tokens[last + 1].start == tokens[last].end):
                last += 1
            boundary = last + 1 == len(tokens) or tokens[last + 1].start > tokens[last].end
        gap = text[tokens[last].end:tokens[last + 1].start] if last + 1 < len(tokens) else ""
        line_break = any(c in _LINE_BREAKS for c in gap)
        if boundary or line_break or last + 1 == len(tokens):
            out.append(text[tokens[first].start:tokens[last].end])
            first = last + 1
        i = last + 1
    return out
