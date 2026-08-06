from __future__ import annotations

import re

import pytest

from app.text_styles import (
    _PUNCTUATION_BY_LANGUAGE,
    SUPPORTED_WRITING_STYLES,
    apply_writing_style,
)

SAMPLES = [
    "I don't think it's ready yet.",
    "Meet me at 3:30, it's about 2.5 miles away.",
    "Email me at john@example.com or see example.com/docs.",
    "Wow. That went really well. I'm so happy.",
    "It cost $1,200 and that's a lot.",
    "I went home. John called me later.",
    "Check https://example.com/a/b?q=1 for details.",
    "Wait... I'm not sure.",
    "Can you send it? I'll wait.",
    "We shipped on the 3rd, e.g. before the U.S. holiday.",
]


def _words(text: str) -> list[str]:
    return re.findall(r"[^\W_]+", text.lower())


@pytest.mark.parametrize("style", sorted(SUPPORTED_WRITING_STYLES))
@pytest.mark.parametrize("sample", SAMPLES)
def test_styles_never_change_the_words(sample: str, style: str) -> None:
    """The documented guarantee: styling is presentation only."""
    assert _words(apply_writing_style(sample, style)) == _words(sample)


@pytest.mark.parametrize("style", sorted(SUPPORTED_WRITING_STYLES))
@pytest.mark.parametrize(
    "fragment",
    [
        "$1,200",
        "2.5",
        "3:30",
        "john@example.com",
        "https://example.com/a/b?q=1",
        "don't",
        "it's",
        "I'll",
    ],
)
def test_meaningful_punctuation_survives_every_style(fragment: str, style: str) -> None:
    """Punctuation inside prices, times, decimals, addresses and contractions
    carries meaning. Removing it silently corrupted the transcript."""
    styled = apply_writing_style(f"Here is {fragment} for you.", style)
    expected = fragment.lower() if style == "very_casual" else fragment
    assert expected in styled


def test_raw_returns_the_model_output_untouched() -> None:
    assert apply_writing_style("  hello   there  ", "raw") == "hello   there"


def test_clean_normalizes_spacing_without_an_opinion_on_case() -> None:
    assert apply_writing_style("hello   there ,ok", "clean") == "hello there,ok."


def test_formal_capitalizes_and_terminates() -> None:
    assert apply_writing_style("hello there. how are you", "formal") == (
        "Hello there. How are you."
    )


def test_casual_drops_only_the_closing_full_stop() -> None:
    assert apply_writing_style("Hello there. It is fine.", "casual") == ("Hello there. It is fine")
    # A question mark carries meaning and is not a decoration to strip.
    assert apply_writing_style("Are we ready?", "casual") == "Are we ready?"


def test_casual_never_demotes_a_name() -> None:
    """Casual keeps sentence structure, so there is no lowercasing decision
    to get wrong and no English stop-word list to maintain."""
    assert apply_writing_style("I went home. John called.", "casual") == (
        "I went home. John called"
    )


def test_very_casual_lowercases_prose_but_not_addresses() -> None:
    styled = apply_writing_style("Email John@Example.com now. Thanks.", "very_casual")
    assert "John@Example.com" in styled
    assert styled.startswith("email")


def test_excited_exclaims_every_statement_and_keeps_questions() -> None:
    assert apply_writing_style("Wow. That worked. I'm happy.", "excited") == (
        "Wow! That worked! I'm happy!"
    )
    assert apply_writing_style("Can you send it? I'll wait.", "excited") == (
        "Can you send it? I'll wait!"
    )


@pytest.mark.parametrize("style", sorted(SUPPORTED_WRITING_STYLES))
def test_an_ellipsis_is_never_mistaken_for_a_sentence_end(style: str) -> None:
    styled = apply_writing_style("Wait... I am not sure.", style)
    assert "..." in styled


def test_a_trailing_address_does_not_gain_a_second_period() -> None:
    assert apply_writing_style("See example.com/docs.", "formal") == ("See example.com/docs.")


def test_empty_input_stays_empty() -> None:
    for style in SUPPORTED_WRITING_STYLES:
        assert apply_writing_style("", style) == ""


def test_unsupported_style_is_rejected() -> None:
    with pytest.raises(ValueError):
        apply_writing_style("hello", "shouty")


# ---------------------------------------------------------------------------
# Languages other than English
#
# Every rule used to assume a Latin full stop and comma, so Japanese came back
# unstyled with a stray "!" appended and Arabic gained Latin commas.
# ---------------------------------------------------------------------------

JAPANESE = "家に帰りました。ジョンが電話してきました。"
ARABIC = "ذهبت إلى المنزل. اتصل بي جون لاحقاً."
KOREAN = "집에 갔어요. 존이 나중에 전화했어요."


def test_japanese_uses_its_own_sentence_marks() -> None:
    assert apply_writing_style(JAPANESE, "excited", "ja") == (
        "家に帰りました！ジョンが電話してきました！"
    )
    assert apply_writing_style(JAPANESE, "casual", "ja") == (
        "家に帰りました。ジョンが電話してきました"
    )
    # No space is inserted between CJK sentences.
    assert " " not in apply_writing_style(JAPANESE, "very_casual", "ja")


def test_arabic_uses_an_arabic_clause_separator() -> None:
    styled = apply_writing_style(ARABIC, "very_casual", "ar")
    assert "،" in styled
    assert "," not in styled


HINDI = "मैं घर गया। जॉन ने बाद में फोन किया।"


def test_hindi_is_terminated_with_a_danda_not_a_full_stop() -> None:
    """Indic scripts end a sentence with "।". Appending "." both looked wrong and,
    because the danda was not recognised as a terminator, produced a second one on
    text the model had already punctuated."""
    assert apply_writing_style(HINDI, "clean", "hi") == HINDI
    assert apply_writing_style("मैं कल बाजार जाऊंगा", "formal", "hi") == "मैं कल बाजार जाऊंगा।"
    # Casual drops the closing danda the way it drops a closing full stop.
    assert apply_writing_style(HINDI, "casual", "hi") == "मैं घर गया। जॉन ने बाद में फोन किया"


def test_hindi_sentences_are_actually_segmented() -> None:
    """Without the danda in `terminators` the whole transcript read as one
    sentence, so very_casual and excited silently did nothing."""
    assert apply_writing_style(HINDI, "excited", "hi") == "मैं घर गया! जॉन ने बाद में फोन किया!"
    assert apply_writing_style(HINDI, "very_casual", "hi") == "मैं घर गया, जॉन ने बाद में फोन किया"


def test_a_danda_is_detected_without_an_explicit_language() -> None:
    """Several models detect the language themselves, so Hindi commonly arrives
    with the request language still set to Automatic."""
    assert apply_writing_style(HINDI, "excited", "auto") == "मैं घर गया! जॉन ने बाद में फोन किया!"


def test_bengali_uses_the_danda_but_tamil_uses_a_full_stop() -> None:
    """Not every Indic script writes the danda: the Dravidian ones use "." in
    modern usage, while still needing to recognise a danda a model may emit."""
    bengali = "আমি ভালো আছি। তুমি কেমন আছো"
    assert apply_writing_style(bengali, "clean", "bn") == "আমি ভালো আছি। তুমি কেমন আছো।"
    tamil = "நான் நன்றாக இருக்கிறேன்"
    assert apply_writing_style(tamil, "clean", "ta") == "நான் நன்றாக இருக்கிறேன்."


def test_thai_and_lao_end_sentences_with_nothing_at_all() -> None:
    """These scripts have no sentence-ending mark, so no style may add one — and
    dropping a zero-length terminator must not truncate the transcript, since
    `"x".endswith("")` is True and `"x"[:-0]` is the empty string."""
    thai = "ผมสบายดี"
    for style in ("clean", "formal", "casual", "very_casual", "excited"):
        styled = apply_writing_style(thai, style, "th")
        assert thai in styled, f"{style} lost the Thai transcript: {styled!r}"
    assert apply_writing_style(thai, "casual", "th") == thai
    assert apply_writing_style(thai, "clean", "th") == thai
    assert apply_writing_style("ຂ້ອຍສະບາຍດີ", "casual", "lo") == "ຂ້ອຍສະບາຍດີ"


def test_scripts_with_their_own_sentence_marks() -> None:
    assert apply_writing_style("ကျွန်တော် အိမ်ပြန်သွားတယ်", "clean", "my").endswith("။")
    assert apply_writing_style("ខ្ញុំសុខសប្បាយជាទេ", "clean", "km").endswith("។")
    assert apply_writing_style("ང་བདེ་པོ་ཡིན", "clean", "bo").endswith("།")
    # Perso-Arabic Indic languages follow Urdu's "۔", not the Arabic full stop.
    assert apply_writing_style("بہٕ چھُس ٹھیک", "clean", "ks").endswith("۔")
    assert apply_writing_style("مان ٺيڪ آهيان", "clean", "sd").endswith("۔")


def test_no_style_ever_erases_a_transcript_containing_words() -> None:
    """The broad invariant behind the per-language tables: whatever the language,
    styling is presentation only and can never leave the user with nothing."""
    samples = ["hello", "मैं ठीक हूँ", "私は元気です", "ผมสบายดี", "مان ٺيڪ آهيان", "hi।", "ok..."]
    languages = sorted(set(_PUNCTUATION_BY_LANGUAGE) | {"en", "auto", "ko", "th"})
    for language in languages:
        for style in SUPPORTED_WRITING_STYLES:
            for sample in samples:
                styled = apply_writing_style(sample, style, language)
                assert styled.strip(), f"{language}/{style} erased {sample!r}"


def test_a_language_pysbd_lacks_still_gets_styled() -> None:
    """Korean has no pysbd profile, so it falls back to terminator splitting."""
    assert apply_writing_style(KOREAN, "excited", "ko") == ("집에 갔어요! 존이 나중에 전화했어요!")


def test_german_abbreviations_come_from_the_segmenter_not_a_word_list() -> None:
    styled = apply_writing_style("Ich ging nach Hause. Herr z.B. Schmidt rief an.", "excited", "de")
    assert styled == "Ich ging nach Hause! Herr z.B. Schmidt rief an!"


def test_auto_infers_the_script_from_the_transcript() -> None:
    """ "auto" is the default, so the script has to be inferred from the text."""
    assert apply_writing_style(JAPANESE, "excited", "auto") == (
        "家に帰りました！ジョンが電話してきました！"
    )


def test_a_country_code_word_is_not_mistaken_for_a_domain() -> None:
    """ ".it" is a real suffix, so "home.It" must not be read as an address."""
    styled = apply_writing_style("I went home.It was fine.", "formal", "en")
    assert styled == "I went home.It was fine."


def test_a_foreign_terminator_is_recognised_not_doubled() -> None:
    """A model that picks its own language leaks that language's punctuation:
    Dolphin ends a Hindi sentence with the CJK "。". Appending a danda to text
    that already ended produced "。।" at the cursor."""
    leaked = "आज मैं ऑफिस जा रहा हूँ。"
    assert apply_writing_style(leaked, "clean", "hi") == leaked
    assert apply_writing_style(leaked, "formal", "hi") == leaked
    # Styles that rewrite terminators normalise it to the right language's mark.
    assert apply_writing_style(leaked, "excited", "hi") == "आज मैं ऑफिस जा रहा हूँ!"
    # The reverse direction too: a danda leaking into Japanese.
    assert apply_writing_style("私は元気です।", "clean", "ja") == "私は元気です।"


def test_recognising_foreign_marks_does_not_change_normal_text() -> None:
    for language, text in (
        ("hi", "मैं घर गया। जॉन ने फोन किया।"),
        ("en", "I went home. John called."),
        ("ja", "家に帰りました。ジョンが電話してきました。"),
        ("ar", "ذهبت إلى المنزل. اتصل بي جون."),
    ):
        assert apply_writing_style(text, "clean", language) == text
