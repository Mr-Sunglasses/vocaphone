from __future__ import annotations

from app.service import conservative_cleanup
from app.text_styles import apply_writing_style


def test_cleanup_is_conservative() -> None:
    assert conservative_cleanup("  hello   world  ") == "hello world."
    assert conservative_cleanup("Already done!") == "Already done!"
    assert conservative_cleanup("space before , punctuation") == "space before, punctuation."


def test_formal_style_capitalizes_and_adds_complete_punctuation() -> None:
    assert (
        apply_writing_style("  hello   world , how are you  ", "formal")
        == "Hello world, how are you."
    )


def test_casual_style_uses_lighter_punctuation() -> None:
    assert (
        apply_writing_style("hello, world; this is relaxed.", "casual")
        == "Hello world this is relaxed"
    )
    assert apply_writing_style("are we ready?", "casual") == "Are we ready?"
    assert (
        apply_writing_style("visit https://example.com, please.", "casual")
        == "Visit https://example.com please"
    )


def test_very_casual_style_is_lowercase_without_punctuation() -> None:
    assert (
        apply_writing_style("Hello, WORLD! Don't stop—now.", "very_casual")
        == "hello world dont stop now"
    )


def test_excited_style_uses_expressive_sentence_endings() -> None:
    assert apply_writing_style("we did it. this works", "excited") == "We did it. This works!"
    assert apply_writing_style("ask Dr. Smith", "excited") == "Ask Dr. Smith!"
