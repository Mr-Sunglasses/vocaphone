from __future__ import annotations

import pytest

from app.errors import LanguageUnsupportedError
from app.scripts import transcript_matches_language
from app.service import _require_matching_script


def test_the_dolphin_cyrillic_bug_is_rejected() -> None:
    """The exact failure this guard exists for: dictating "नमस्ते" in Hindi to
    Dolphin returns "насте" — fluent, confident, and in the wrong alphabet."""
    assert transcript_matches_language("насте", "hi") is False
    with pytest.raises(LanguageUnsupportedError, match="different language"):
        _require_matching_script("насте", "hi")


def test_transliteration_into_another_script_is_rejected() -> None:
    """Omnilingual rendered "send me the report by Friday" as Arabic. A presence
    test let it through on the single stray Latin "o" in "رoرت", which is why the
    check is proportional rather than binary."""
    transliterated = "ل سند مي  رoرت بي فريداي"
    assert "o" in transliterated  # the character that used to rescue it
    assert transcript_matches_language(transliterated, "en") is False
    with pytest.raises(LanguageUnsupportedError):
        _require_matching_script(transliterated, "en")


def test_code_switching_is_never_rejected() -> None:
    """Indian speakers routinely mix English into Hindi. The check only fires
    when there is no trace of the expected script at all."""
    # Including heavy Hinglish, which is where a proportional check could bite.
    for text in (
        "मैं office जा रहा हूँ",
        "मैं ठीक हूँ",
        "kal मैं आऊंगा",
        "मैं report Friday तक send करूंगा",
        "ठीक है OK",
    ):
        assert transcript_matches_language(text, "hi") is True
        _require_matching_script(text, "hi")


def test_uncertain_cases_pass_rather_than_fail() -> None:
    """Anything the check cannot judge must be let through: a guard that guesses
    would reject good transcripts."""
    assert transcript_matches_language("anything at all", "auto") is True
    assert transcript_matches_language("anything at all", "zz") is True  # unknown code
    assert transcript_matches_language("", "hi") is True
    assert transcript_matches_language("1,200 $45 —", "hi") is True  # no letters
    # Chinese and Japanese share Han characters, so CJK is deliberately lenient.
    assert transcript_matches_language("私は元気です", "zh") is True


@pytest.mark.parametrize(
    ("text", "language"),
    [
        ("मैं ठीक हूँ", "en"),
        ("hello there", "hi"),
        ("आज", "bn"),
        ("The quick brown fox", "ru"),
        ("مرحبا", "hi"),
    ],
)
def test_wrong_script_is_rejected(text: str, language: str) -> None:
    assert transcript_matches_language(text, language) is False


@pytest.mark.parametrize(
    ("text", "language"),
    [
        ("मैं कल बाजार जाऊंगा", "hi"),
        ("আমি ভালো আছি", "bn"),
        ("நான் நன்றாக இருக்கிறேன்", "ta"),
        ("私は元気です", "ja"),
        ("집에 갔어요", "ko"),
        ("ผมสบายดี", "th"),
        ("The quick brown fox", "en"),
        ("Здравствуйте", "ru"),
        ("مان ٺيڪ آهيان", "sd"),
    ],
)
def test_matching_script_passes(text: str, language: str) -> None:
    assert transcript_matches_language(text, language) is True
    _require_matching_script(text, language)


def test_every_client_language_can_be_judged() -> None:
    """A language the clients offer but the table does not know would silently
    skip the guard, which is how this class of bug goes unnoticed."""
    from app.scripts import expected_scripts

    client_languages = [
        "en", "es", "ar", "ja", "ko", "zh", "uk", "ru", "vi", "fr", "de", "it",
        "pt", "nl", "pl", "hi", "bn", "mr", "te", "ta", "gu", "ur", "kn", "ml",
        "pa", "as", "ne",
    ]  # fmt: skip
    unjudgeable = [code for code in client_languages if not expected_scripts(code)]
    assert not unjudgeable, f"no expected script for: {unjudgeable}"
