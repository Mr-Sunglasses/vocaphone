"""Detect when a transcript came back in the wrong writing system.

Several catalog models decide the language themselves and cannot be pinned
(Dolphin, SenseVoice, Qwen3-ASR). On a short recording — which is most of
dictation — their detection can land on a completely unrelated language:
"ठीक है" comes back from both Dolphin and Qwen3-ASR as Chinese, and "नमस्ते"
from Dolphin as Cyrillic.

That is worse than an error, because it reaches the cursor looking like a real
transcript. Comparing the script of the result against the script the requested
language is written in turns a silent wrong answer into an honest failure.

The check is deliberately lenient, since a false rejection throws away a good
transcript. It never fires on an unknown language, on `auto`, or on text without
letters, and it requires only a minority of letters to be in the expected script
so that code-switching ("मैं report Friday तक send करूंगा") always passes.
"""

from __future__ import annotations

import unicodedata

# Unicode character names begin with the script, so "DEVANAGARI LETTER MA" and
# "CYRILLIC SMALL LETTER A" identify themselves without a table of code ranges.
_LATIN = frozenset({"LATIN"})
_ARABIC = frozenset({"ARABIC"})
_CYRILLIC = frozenset({"CYRILLIC"})
_DEVANAGARI = frozenset({"DEVANAGARI"})
_BENGALI = frozenset({"BENGALI"})
# Japanese mixes three scripts, and Chinese characters are named "CJK ...".
_JAPANESE = frozenset({"HIRAGANA", "KATAKANA", "CJK"})
_CHINESE = frozenset({"CJK"})

EXPECTED_SCRIPTS: dict[str, frozenset[str]] = {
    # Indic
    "hi": _DEVANAGARI,
    "mr": _DEVANAGARI,
    "ne": _DEVANAGARI,
    "sa": _DEVANAGARI,
    "kok": _DEVANAGARI,
    "mai": _DEVANAGARI,
    "bn": _BENGALI,
    "as": _BENGALI,
    "ta": frozenset({"TAMIL"}),
    "te": frozenset({"TELUGU"}),
    "kn": frozenset({"KANNADA"}),
    "ml": frozenset({"MALAYALAM"}),
    "gu": frozenset({"GUJARATI"}),
    "pa": frozenset({"GURMUKHI"}),
    "or": frozenset({"ORIYA"}),
    "si": frozenset({"SINHALA"}),
    # Perso-Arabic
    "ar": _ARABIC,
    "fa": _ARABIC,
    "ps": _ARABIC,
    "ur": _ARABIC,
    "sd": _ARABIC,
    "ks": _ARABIC,
    "ug": _ARABIC,
    # Cyrillic
    "ru": _CYRILLIC,
    "uk": _CYRILLIC,
    "be": _CYRILLIC,
    "bg": _CYRILLIC,
    "mn": _CYRILLIC,
    "kk": _CYRILLIC,
    "ky": _CYRILLIC,
    "tg": _CYRILLIC,
    "ba": _CYRILLIC,
    "tt": _CYRILLIC,
    # East and Southeast Asian
    "ja": _JAPANESE,
    "zh": _CHINESE,
    "yue": _CHINESE,
    "ct": _CHINESE,
    "ko": frozenset({"HANGUL"}),
    "th": frozenset({"THAI"}),
    "lo": frozenset({"LAO"}),
    "my": frozenset({"MYANMAR"}),
    "km": frozenset({"KHMER"}),
    "bo": frozenset({"TIBETAN"}),
    # Other non-Latin
    "el": frozenset({"GREEK"}),
    "he": frozenset({"HEBREW"}),
    "yi": frozenset({"HEBREW"}),
    "hy": frozenset({"ARMENIAN"}),
    "ka": frozenset({"GEORGIAN"}),
    "am": frozenset({"ETHIOPIC"}),
}

# Everything the clients can request that is written in the Latin alphabet. Kept
# explicit rather than assumed as a default, so an unknown code skips the check
# instead of being wrongly held to Latin.
_LATIN_LANGUAGES = frozenset(
    {
        "en", "es", "fr", "de", "it", "pt", "nl", "pl", "vi", "id", "ms", "tl",
        "fil", "sv", "da", "no", "nn", "fi", "et", "lv", "lt", "cs", "sk", "sl",
        "hr", "bs", "sq", "ro", "hu", "mt", "tr", "az", "uz", "af", "ca", "eu",
        "gl", "cy", "br", "is", "la", "lb", "ln", "mg", "mi", "oc", "sn", "so",
        "sw", "tk", "yo", "ha", "haw", "ht", "jv", "jw", "su", "kab", "fo", "sr",
    }
)  # fmt: skip


def _script_of(character: str) -> str:
    try:
        return unicodedata.name(character).split(" ", 1)[0]
    except ValueError:  # unnamed control or private-use character
        return ""


def expected_scripts(language: str) -> frozenset[str]:
    """The writing systems a language is normally transcribed in, or empty when
    the language is unknown and no claim should be made."""
    code = language.lower().split("-", maxsplit=1)[0]
    if code in EXPECTED_SCRIPTS:
        return EXPECTED_SCRIPTS[code]
    return _LATIN if code in _LATIN_LANGUAGES else frozenset()


# Share of letters that must be in the expected script. A presence test alone was
# not enough: a model under evaluation transliterated "send me the report by Friday" into Arabic
# as "ل سند مي رoرت بي فريداي", whose single stray Latin "o" passed it. Genuine
# code-switching keeps far more of the base script than that — Hinglish rarely
# drops below a third — so this sits well below any real transcript.
_MINIMUM_EXPECTED_SHARE = 0.15


def transcript_matches_language(text: str, language: str) -> bool:
    """Whether `text` could plausibly be `language`.

    True whenever the answer is uncertain: an unknown language, or a transcript
    with no letters at all. Otherwise the expected script has to account for at
    least `_MINIMUM_EXPECTED_SHARE` of the letters, which admits code-switching
    while rejecting text transliterated into another writing system entirely.
    """
    if language == "auto":
        return True
    expected = expected_scripts(language)
    if not expected:
        return True
    letters = [character for character in text if character.isalpha()]
    if not letters:
        return True
    matching = sum(1 for character in letters if _script_of(character) in expected)
    return matching / len(letters) >= _MINIMUM_EXPECTED_SHARE
