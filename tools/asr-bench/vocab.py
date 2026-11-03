"""Vocabulary terms in the `vocab-en` set: which a sentence uses, how it is
spoken, the Dictionary a user would have entered for it, and whether a
transcript spelled them.

Standard library only, so `prepare.py`, `score.py` and the offline tests all
share one definition of what counts as a term being "spelled exactly".
"""

from __future__ import annotations

import hashlib
import re


def pattern(term: str) -> re.Pattern[str]:
    """`term` exactly, case and all, not inside a longer word.

    A letter or digit either side is a longer word ("GitHubs", "Redisson");
    anything else, an apostrophe included, is a boundary, so "Anthropic's"
    holds "Anthropic".
    """
    return re.compile(r"(?<![A-Za-z0-9])" + re.escape(term) + r"(?![A-Za-z0-9])")


def occurrences(text: str, term: str) -> int:
    return len(pattern(term).findall(text))


def expected_terms(sentence: str, dictionary: list[str]) -> list[str]:
    """The Dictionary terms `sentence` uses, in Dictionary order."""
    return [term for term in dictionary if occurrences(sentence, term)]


def spoken(sentence: str, forms: dict[str, str]) -> str:
    """`sentence` as the speaker says it: every term with a spoken form
    replaced by that form, longest term first so "sherpa-onnx" is not read as
    "sherpa-" and a separately spoken "ONNX"."""
    for term in sorted(forms, key=len, reverse=True):
        sentence = pattern(term).sub(forms[term], sentence)
    return sentence


def _rank(seed: str, term: str) -> str:
    return hashlib.sha256(f"{seed}\0{term}".encode()).hexdigest()


def clip_vocabulary(clip_id: str, terms: list[str], dictionary: list[str], distractors: int) -> list[str]:
    """The Dictionary a user would have entered for this dictation.

    The terms the sentence uses and `distractors` others from the same
    Dictionary, so the hint is not a list of exactly the words about to be
    said. Chosen and ordered by a hash of the clip id: the same every run,
    and no term always first or last.
    """
    others = sorted((t for t in dictionary if t not in terms), key=lambda t: _rank(clip_id, t))
    chosen = list(terms) + others[:distractors]
    return sorted(chosen, key=lambda t: _rank(clip_id + "/order", t))


def term_hits(reference: str, hypothesis: str, terms: list[str]) -> tuple[int, int]:
    """(spelled, expected): every time the reference uses a term counts once,
    and is spelled when the hypothesis has that term, exactly, as many times."""
    spelled = expected = 0
    for term in terms:
        wanted = occurrences(reference, term)
        expected += wanted
        spelled += min(wanted, occurrences(hypothesis, term))
    return spelled, expected
