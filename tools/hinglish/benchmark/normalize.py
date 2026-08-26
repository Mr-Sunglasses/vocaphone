#!/usr/bin/env python3
"""A Python port of the app's Roman Hinglish normalization layer.

Mirrors `core/HinglishNormalizer.kt` and `core/DevanagariRomanizer.kt`, so that
`score.py --normalize` measures what a user would actually see rather than the
raw decode. The rules and the tables are documented once, in
`docs/hinglish-roman.md`; the reasoning behind each is in the Kotlin.

Third copy of the same logic, which is a real cost. It buys the one number that
decides whether the normalizer earns its place — leakage and WER with it against
leakage and WER without it — and the parity test below is what keeps the copy
from drifting silently:

    python3 tools/hinglish/benchmark/normalize.py --self-test
"""

from __future__ import annotations

import re
import sys
import unicodedata

# ------------------------------------------------------------ transliteration

VIRAMA, NUKTA, ANUSVARA, CHANDRABINDU, VISARGA = "\u094d", "\u093c", "\u0902", "\u0901", "\u0903"
ZWJ, ZWNJ = "\u200d", "\u200c"
NASAL_SIGNS = {ANUSVARA, CHANDRABINDU, VISARGA}
JOINERS = {ZWJ, ZWNJ}
LABIALS = {"p", "b", "m"}

# (non-final, final). Only the long vowels differ; a long vowel shortens at the
# end of a word, so आज is "aaj" and करना is "karna".
VOWELS = {
    "A": ("a", "a"), "AA": ("aa", "a"), "I": ("i", "i"), "II": ("ee", "i"),
    "U": ("u", "u"), "UU": ("oo", "u"), "RI": ("ri", "ri"), "E": ("e", "e"),
    "AI": ("ai", "ai"), "O": ("o", "o"), "AU": ("au", "au"),
}

INDEPENDENT = {
    "अ": "A", "आ": "AA", "इ": "I", "ई": "II", "उ": "U", "ऊ": "UU",
    "ऋ": "RI", "ॠ": "RI", "ऍ": "E", "ए": "E", "ऎ": "E", "ऐ": "AI",
    "ऑ": "O", "ओ": "O", "ऒ": "O", "औ": "AU",
}

MATRAS = {
    "\u093e": "AA", "\u093f": "I", "\u0940": "II", "\u0941": "U", "\u0942": "UU",
    "\u0943": "RI", "\u0944": "RI", "\u0945": "E", "\u0946": "E", "\u0947": "E",
    "\u0948": "AI", "\u0949": "O", "\u094a": "O", "\u094b": "O", "\u094c": "AU",
}

CONSONANTS = {
    "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
    "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
    "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
    "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
    "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m",
    "य": "y", "र": "r", "ऱ": "r", "ल": "l", "ळ": "l", "व": "v",
    "श": "sh", "ष": "sh", "स": "s", "ह": "h",
    "\u0958": "q", "\u0959": "kh", "\u095a": "gh", "\u095b": "z",
    "\u095c": "r", "\u095d": "rh", "\u095e": "f", "\u095f": "y",
}

NUKTA_FORMS = {
    "क": "q", "ख": "kh", "ग": "gh", "ज": "z",
    "ड": "r", "ढ": "rh", "फ": "f", "य": "y",
}

# Devanagari that is not part of a syllable. These end a word rather than
# joining it: with the danda counted in, ठीक। keeps a syllable after क and
# romanizes as "theeka.".
STANDALONE = {
    "।": ".", "॥": ".", "ॐ": "om", "ऽ": "",
    "०": "0", "१": "1", "२": "2", "३": "3", "४": "4",
    "५": "5", "६": "6", "७": "7", "८": "8", "९": "9",
}


def _is_devanagari(character: str) -> bool:
    return "\u0900" <= character <= "\u097f"


def _parse(word: str) -> list[list]:
    """Into syllables of [onset, vowel, implicit, nasal]."""
    syllables: list[list] = []
    index = 0
    while index < len(word):
        character = word[index]
        if character in JOINERS:
            index += 1
        elif character in INDEPENDENT:
            syllables.append(["", INDEPENDENT[character], False, ""])
            index += 1
        elif character in CONSONANTS:
            onset = CONSONANTS[character]
            index += 1
            if index < len(word) and word[index] == NUKTA:
                onset = NUKTA_FORMS.get(character, onset)
                index += 1
            vowel, implicit = "A", True
            if index < len(word):
                if word[index] == VIRAMA:
                    vowel, implicit = None, False
                    index += 1
                elif word[index] in MATRAS:
                    vowel, implicit = MATRAS[word[index]], False
                    index += 1
            syllables.append([onset, vowel, implicit, ""])
        else:
            index += 1
        while index < len(word) and word[index] in NASAL_SIGNS:
            if syllables:
                syllables[-1][3] = "h" if word[index] == VISARGA else "n"
            index += 1
    return syllables


def _delete_schwa(syllables: list[list]) -> None:
    """Word-finally always; mid-word only before a written vowel, and never on
    the first syllable, which is what keeps पता from becoming "pta"."""
    for index, syllable in enumerate(syllables):
        if not syllable[2] or not syllable[0]:
            continue
        is_last = index == len(syllables) - 1
        next_written = (
            not is_last
            and syllables[index + 1][1] is not None
            and not syllables[index + 1][2]
        )
        if is_last or (index > 0 and next_written):
            syllable[1], syllable[2] = None, False


def _render(syllables: list[list]) -> str:
    # Whether any *letter* comes after, not whether any vowel does: schwa
    # deletion leaves ज in आज carrying no vowel, and judging by vowels alone
    # makes the ā look final and spells it "aj".
    last_letter = max(
        (i for i, s in enumerate(syllables) if s[0] or s[1] is not None), default=-1
    )
    out = []
    for index, (onset, vowel, _implicit, nasal) in enumerate(syllables):
        out.append(onset)
        if vowel is not None:
            out.append(VOWELS[vowel][1 if index == last_letter else 0])
        if nasal == "n":
            following = syllables[index + 1][0] if index + 1 < len(syllables) else ""
            out.append("m" if following[:1] in LABIALS else "n")
        else:
            out.append(nasal)
    return "".join(out)


def romanize(text: str) -> str:
    if not any(_is_devanagari(c) for c in text):
        return text
    out, word = [], []

    def flush():
        if word:
            syllables = _parse("".join(word))
            _delete_schwa(syllables)
            out.append(_render(syllables))
            word.clear()

    for character in text:
        if _is_devanagari(character) and character not in STANDALONE:
            word.append(character)
        elif character in JOINERS:
            word.append(character)
        elif character in STANDALONE:
            flush()
            out.append(STANDALONE[character])
        else:
            flush()
            out.append(character)
    flush()
    return "".join(out)


# ------------------------------------------------------------- normalization

PROTECTED = re.compile(
    "|".join([
        r"(?i:\b(?:[a-z][a-z0-9+.-]*://|www\.)\S+)",
        r"(?i:\b[\w.+-]+@[\w-]+\.[\w.-]+\b)",
        r"\S*[/\\]\S*",
        r"(?i:\b\w+\.[a-z0-9]{1,8}\b)",
        r"[@#][\w.-]+",
        r"\b[A-Z][A-Z0-9]{1,7}\b",
    ])
)
WORD = re.compile(r"[^\W\d_]+", re.UNICODE)
PLACEHOLDER = re.compile("\u0001(\\d+)\u0002")
HEY = re.compile(r"(?<=\S )hey\b(?![,!])")

ROMANIZED_CONVENTIONS = {
    "men": "mein", "kyon": "kyun", "kyonki": "kyunki",
    "hon": "hoon", "hun": "hoon", "jaen": "jayen",
}

GLOBAL_CONVENTIONS = {
    "muje": "mujhe", "mujey": "mujhe", "mujhy": "mujhe",
    "kyu": "kyun", "kyoon": "kyun", "kyuki": "kyunki", "kyunke": "kyunki",
    "nahi": "nahin", "nhi": "nahin",
    "thik": "theek", "thk": "theek",
    "acha": "accha", "achha": "accha",
    "bahot": "bahut", "bhot": "bahut",
    "kese": "kaise", "krna": "karna", "krke": "karke", "smjh": "samajh",
}


def _match_case(original: str, replacement: str) -> str:
    if len(original) > 1 and original.isupper():
        return replacement.upper()
    if original[:1].isupper():
        return replacement[:1].upper() + replacement[1:]
    return replacement


def normalize(
    text: str,
    transliterate: bool = True,
    romanized_conventions: bool = True,
    global_conventions: bool = True,
    punctuation: bool = True,
) -> str:
    if not text.strip():
        return ""

    tokens: list[str] = []

    def stash(match):
        tokens.append(match.group(0))
        return f"\u0001{len(tokens) - 1}\u0002"

    result = PROTECTED.sub(stash, text)

    if transliterate and any(_is_devanagari(c) for c in result):
        original = set(WORD.findall(result))
        romanized = romanize(result)
        if romanized_conventions:
            def settle(match):
                word = match.group(0)
                if word in original:
                    return word
                replacement = ROMANIZED_CONVENTIONS.get(word.lower())
                return _match_case(word, replacement) if replacement else word

            result = WORD.sub(settle, romanized)
        else:
            result = romanized

    if global_conventions:
        def settle_global(match):
            replacement = GLOBAL_CONVENTIONS.get(match.group(0).lower())
            return _match_case(match.group(0), replacement) if replacement else match.group(0)

        result = HEY.sub("hai", WORD.sub(settle_global, result))

    if punctuation:
        result = result.replace("।", ".").replace("॥", ".")
        result = re.sub(r"[ \t]{2,}", " ", result)
        result = re.sub(r" +([,.!?;:])", r"\1", result)
        result = re.sub(r"([,.!?;:])(?=[^\s\d,.!?;:])", r"\1 ", result)
        result = "\n".join(line.strip() for line in result.split("\n"))

    result = PLACEHOLDER.sub(lambda m: tokens[int(m.group(1))], result)
    return unicodedata.normalize("NFC", result).strip()


def contains_devanagari(text: str) -> bool:
    return any(_is_devanagari(c) for c in text)


# ------------------------------------------------------------------ self-test

# The same cases the Kotlin and Swift suites assert, so a drift in any one of
# the three copies shows up here rather than in a benchmark number nobody can
# explain. Keep in step with `DevanagariRomanizerTest.kt`.
_CASES = [
    ("घर", "ghar"), ("कल", "kal"), ("एक", "ek"), ("आज", "aaj"),
    ("करना", "karna"), ("करनी", "karni"), ("देखना", "dekhna"),
    ("समझ", "samajh"), ("भारत", "bhaarat"),
    ("पता", "pata"), ("बताना", "bataana"),
    ("ठीक", "theek"), ("कभी", "kabhi"), ("काम", "kaam"), ("दूसरा", "doosra"),
    ("नहीं", "nahin"), ("हूँ", "hun"), ("मैं", "main"), ("हैं", "hain"),
    ("संभव", "sambhav"), ("अंदर", "andar"),
    ("क्या", "kya"), ("नमस्ते", "namaste"), ("कुछ", "kuchh"),
    ("ज़रूर", "zaroor"), ("फ़ोन", "fon"), ("बड़ा", "bara"),
    ("१२३", "123"), ("ठीक।", "theek."),
]

_NORMALIZED = [
    ("आज मुझे office में एक important meeting attend करनी है",
     "aaj mujhe office mein ek important meeting attend karni hai"),
    ("Three men joined the call.", "Three men joined the call."),
    ("Sab theek hey", "Sab theek hai"),
    ("Hey, kaise ho?", "Hey, kaise ho?"),
    ("Haan ,   theek hai.", "Haan, theek hai."),
]


def _self_test() -> int:
    failures = 0
    for source, expected in _CASES:
        actual = romanize(source)
        if actual != expected:
            print(f"romanize({source!r}) == {actual!r}, expected {expected!r}")
            failures += 1
    for source, expected in _NORMALIZED:
        actual = normalize(source)
        if actual != expected:
            print(f"normalize({source!r}) == {actual!r}, expected {expected!r}")
            failures += 1
    total = len(_CASES) + len(_NORMALIZED)
    print(f"{total - failures}/{total} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        raise SystemExit(_self_test())
    for line in sys.stdin:
        print(normalize(line.rstrip("\n")))
