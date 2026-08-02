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


def test_casual_style_drops_only_the_closing_period() -> None:
    """Commas used to be stripped wholesale, which corrupted prices and lists.
    Casual now differs from formal by running sentences together instead."""
    assert (
        apply_writing_style("hello, world; this is relaxed.", "casual")
        == "Hello, world; this is relaxed"
    )
    assert apply_writing_style("are we ready?", "casual") == "Are we ready?"
    assert (
        apply_writing_style("visit https://example.com, please.", "casual")
        == "Visit https://example.com, please"
    )
    assert apply_writing_style("Hello there. It is fine.", "casual") == (
        "Hello there. It is fine"
    )


def test_very_casual_style_lowercases_without_mangling_words() -> None:
    """Stripping every punctuation mark turned "Don't" into "dont" and broke
    decimals, times and addresses. Only the casing is casual now."""
    assert (
        apply_writing_style("Hello, WORLD! Don't stop—now.", "very_casual")
        == "hello, world! don't stop—now"
    )


def test_excited_style_exclaims_every_statement() -> None:
    assert apply_writing_style("we did it. this works", "excited") == "We did it! This works!"
    assert apply_writing_style("ask Dr. Smith", "excited") == "Ask Dr. Smith!"
