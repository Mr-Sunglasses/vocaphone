from __future__ import annotations

import re
import unicodedata

SUPPORTED_WRITING_STYLES = frozenset({"raw", "clean", "formal", "casual", "very_casual", "excited"})


def apply_writing_style(text: str, style: str) -> str:
    """Format a local transcript without changing its words or meaning."""
    if style == "raw":
        return text.strip()
    if style == "clean":
        return _clean(text)
    if style == "formal":
        return _formal(text)
    if style == "casual":
        return _casual(text)
    if style == "very_casual":
        return _very_casual(text)
    if style == "excited":
        return _excited(text)
    raise ValueError(f"Unsupported writing style: {style}")


def _normalize_spacing(text: str) -> str:
    result = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"\s+([,.;:!?])", r"\1", result)


def _capitalize_sentence_starts(text: str) -> str:
    pattern = re.compile(r'(^|[.!?]\s+)(["\'“‘(\[]*)([^\W\d_])', re.UNICODE)
    return pattern.sub(
        lambda match: match.group(1) + match.group(2) + match.group(3).upper(),
        text,
    )


def _formal(text: str) -> str:
    result = _capitalize_sentence_starts(_normalize_spacing(text))
    if result and result[-1] not in ".!?":
        result += "."
    return result


def _clean(text: str) -> str:
    result = _normalize_spacing(text)
    if result and result[-1] not in ".!?":
        result += "."
    return result


def _casual(text: str) -> str:
    result = _normalize_spacing(text)
    # Keep colons so URLs, times, and common emoji sequences remain usable.
    result = re.sub(r"[,;]+", "", result)
    result = re.sub(r"\s+", " ", result).strip()
    result = _capitalize_sentence_starts(result)
    return result[:-1] if result.endswith(".") else result


def _very_casual(text: str) -> str:
    result: list[str] = []
    separators = {",", ";", ":", "/", "-", "‐", "‑", "–", "—"}
    for character in _normalize_spacing(text).lower():
        if not unicodedata.category(character).startswith("P"):
            result.append(character)
        elif character in separators:
            result.append(" ")
    return re.sub(r"\s+", " ", "".join(result)).strip()


def _excited(text: str) -> str:
    result = _formal(text)
    result = re.sub(r"!+", "!", result)
    return result[:-1] + "!" if result.endswith(".") else result
