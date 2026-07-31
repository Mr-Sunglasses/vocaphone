from __future__ import annotations

from app.service import conservative_cleanup


def test_cleanup_is_conservative() -> None:
    assert conservative_cleanup("  hello   world  ") == "hello world."
    assert conservative_cleanup("Already done!") == "Already done!"
    assert conservative_cleanup("space before , punctuation") == "space before, punctuation."
