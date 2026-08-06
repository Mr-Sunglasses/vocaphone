from __future__ import annotations

import re
import threading
from dataclasses import dataclass

import pysbd
import tldextract
from pysbd.languages import LANGUAGE_CODES

SUPPORTED_WRITING_STYLES = frozenset({"raw", "clean", "formal", "casual", "very_casual", "excited"})

# ---------------------------------------------------------------------------
# Language-dependent punctuation
#
# Sentence and clause marks are not universal. Assuming "." and "," turned
# Japanese into an unstyled passthrough with a stray "!" appended, and inserted
# Latin commas into Arabic.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Punctuation:
    terminator: str
    separator: str
    exclamation: str
    question: str
    terminators: str
    segmentation_language: str
    # CJK does not put a space between sentences.
    join: str

    def __post_init__(self) -> None:
        # A model that picks its own language leaks that language's punctuation
        # into another script: Dolphin ends a Hindi sentence with the CJK "。".
        # Recognising every sentence mark stops a second terminator being
        # appended to text that already ended — the visible bug was "。।" — and
        # lets the segmenter see the boundary. Only `terminator`, the mark that
        # gets *written*, stays language-specific.
        merged = self.terminators + _UNIVERSAL_TERMINATORS
        object.__setattr__(self, "terminators", "".join(dict.fromkeys(merged)))


# Every sentence-ending mark any catalog model is capable of emitting.
_UNIVERSAL_TERMINATORS = ".!?。！？।۔။។།؟"


_LATIN = Punctuation(".", ",", "!", "?", ".!?", "en", " ")
_CJK = Punctuation("。", "、", "！", "？", "。！？.!?", "ja", "")
_ARABIC = Punctuation(".", "،", "!", "؟", ".!?؟", "ar", " ")
_URDU = Punctuation("۔", "،", "!", "؟", "۔.!?؟", "ur", " ")

# Indic scripts end a sentence with the danda "।" (U+0964), not a full stop, and
# use the Latin comma, question mark and exclamation mark. Both the danda and "."
# are accepted as terminators, because a model trained on mixed corpora emits
# either — recognising only one of them appended a second terminator to text that
# already had one, and hid every sentence boundary from the segmenter.
_DANDA = Punctuation("।", ",", "!", "?", "।.!?", "hi", " ")
# Dravidian scripts and modern Gujarati write the full stop instead, but still
# have to recognise a danda the model may have produced.
_INDIC_LATIN = Punctuation(".", ",", "!", "?", "।.!?", "en", " ")

# Thai and Lao mark a sentence end with a space and nothing else. The empty
# terminator means "append nothing"; `_casual` guards against it explicitly,
# because dropping a zero-length terminator would truncate the whole transcript.
_UNTERMINATED = Punctuation("", " ", "!", "?", "!?", "th", " ")
# Southeast and Central Asian scripts with their own sentence marks.
_BURMESE = Punctuation("။", "၊", "!", "?", "။.!?", "my", " ")
_KHMER = Punctuation("។", ",", "!", "?", "។.!?", "km", " ")
_TIBETAN = Punctuation("།", "།", "!", "?", "།.!?", "bo", " ")


def _replace_segmentation_language(base: Punctuation, code: str) -> Punctuation:
    if code == base.segmentation_language:
        return base
    return Punctuation(
        base.terminator,
        base.separator,
        base.exclamation,
        base.question,
        base.terminators,
        code,
        base.join,
    )


_PUNCTUATION_BY_LANGUAGE = {
    "ja": _CJK,
    "zh": _CJK,
    "yue": _CJK,
    "ar": _ARABIC,
    "fa": _ARABIC,
    "ps": _ARABIC,
    "ur": _URDU,
    # pysbd covers Hindi and Marathi; the rest fall back to splitting on a
    # terminator run, which is all a danda-delimited sentence needs anyway.
    "hi": _DANDA,
    "mr": _replace_segmentation_language(_DANDA, "mr"),
    "ne": _replace_segmentation_language(_DANDA, "ne"),
    "sa": _replace_segmentation_language(_DANDA, "sa"),
    "bn": _replace_segmentation_language(_DANDA, "bn"),
    "as": _replace_segmentation_language(_DANDA, "as"),
    "pa": _replace_segmentation_language(_DANDA, "pa"),
    "or": _replace_segmentation_language(_DANDA, "or"),
    "kok": _replace_segmentation_language(_DANDA, "kok"),
    "mai": _replace_segmentation_language(_DANDA, "mai"),
    "brx": _replace_segmentation_language(_DANDA, "brx"),
    "doi": _replace_segmentation_language(_DANDA, "doi"),
    "ta": _replace_segmentation_language(_INDIC_LATIN, "ta"),
    "te": _replace_segmentation_language(_INDIC_LATIN, "te"),
    "kn": _replace_segmentation_language(_INDIC_LATIN, "kn"),
    "ml": _replace_segmentation_language(_INDIC_LATIN, "ml"),
    "gu": _replace_segmentation_language(_INDIC_LATIN, "gu"),
    # Modern Sinhala writes the full stop; the traditional kunddaliya is not used.
    "si": _replace_segmentation_language(_INDIC_LATIN, "si"),
    # Perso-Arabic scripts follow Urdu rather than Arabic: they end on "۔".
    "sd": _replace_segmentation_language(_URDU, "sd"),
    "ks": _replace_segmentation_language(_URDU, "ks"),
    "ug": _replace_segmentation_language(_ARABIC, "ug"),
    "th": _UNTERMINATED,
    "lo": _replace_segmentation_language(_UNTERMINATED, "lo"),
    "my": _BURMESE,
    "km": _KHMER,
    "bo": _TIBETAN,
}

# Used when the caller says "auto", which is the default, so the script has to
# be inferred from the transcript itself.
_CJK_MARKS = "。、！？"
_ARABIC_MARKS = "،؟"


def _resolve_punctuation(language: str, text: str) -> Punctuation:
    code = language.lower().split("-")[0]
    known = _PUNCTUATION_BY_LANGUAGE.get(code)
    if known is not None:
        return known
    if code not in ("auto", ""):
        return _replace_segmentation_language(_LATIN, code)
    if any(mark in text for mark in _CJK_MARKS):
        return _CJK
    if any(mark in text for mark in _ARABIC_MARKS):
        return _ARABIC
    if "۔" in text:
        return _URDU
    # Auto matters more than usual here: several models detect the language
    # themselves, so a Hindi transcript often arrives with the language still
    # set to Automatic.
    if "।" in text:
        return _DANDA
    return _LATIN


# ---------------------------------------------------------------------------
# Protected spans
#
# Punctuation inside a price, time, decimal, address or contraction carries
# meaning. These spans are masked before any transform and restored afterwards,
# so no style can corrupt them. Sentence-ending abbreviations such as "Dr." are
# deliberately not listed here: pysbd already knows them, per language.
# ---------------------------------------------------------------------------

_PLACEHOLDER_START = ""
_PLACEHOLDER_END = ""
_PLACEHOLDER = re.compile(rf"{_PLACEHOLDER_START}(\d+){_PLACEHOLDER_END}")

_TRAILING = r"[^\s.,;:!?'\"“”)\]]"
_SCHEME_URL = rf"[A-Za-z][A-Za-z0-9+.\-]*://[^\s]*{_TRAILING}"
_EMAIL = r"[\w.+\-]+@(?:[\w\-]+\.)+[A-Za-z]{2,}"
_DOMAIN = rf"(?:[\w\-]+\.)+[A-Za-z]{{2,24}}(?:/[^\s]*{_TRAILING})?"

_PROTECTED = re.compile(
    rf"""(
        (?P<url>{_SCHEME_URL})
      | (?P<email>{_EMAIL})
      | (?P<domain>{_DOMAIN})
      | (?P<number>\d+(?:[.,:/]\d+)+)
      | (?P<ordinal>\d+(?:st|nd|rd|th)\b)
      | (?P<acronym>(?:[A-Za-z]\.){{2,}})
      | (?P<contraction>\w+['’]\w+)
    )""",
    re.VERBOSE,
)

_ADDRESS = re.compile(rf"^(?:{_SCHEME_URL}|{_EMAIL})$")

# The Public Suffix List snapshot bundled with tldextract. Network lookups are
# disabled so a local gateway never stalls on a suffix refresh.
_SUFFIXES = tldextract.TLDExtract(suffix_list_urls=(), cache_dir=None)


def _is_real_domain(candidate: str) -> bool:
    host = candidate.split("/", 1)[0]
    suffix = host.rsplit(".", 1)[-1]
    # ".it" and ".in" are real country domains, so "I went home.It was fine"
    # would otherwise be read as an address. Transcribed hosts are lower case.
    if not suffix.islower():
        return False
    return bool(_SUFFIXES(host).suffix)


def _protect(text: str) -> tuple[str, list[str]]:
    tokens: list[str] = []

    def capture(match: re.Match[str]) -> str:
        span = match.group(0)
        if match.lastgroup == "domain" and not _is_real_domain(span):
            return span
        tokens.append(span)
        return f"{_PLACEHOLDER_START}{len(tokens) - 1}{_PLACEHOLDER_END}"

    return _PROTECTED.sub(capture, text), tokens


def _restore(text: str, tokens: list[str]) -> str:
    if not tokens:
        return text
    return _PLACEHOLDER.sub(lambda match: tokens[int(match.group(1))], text)


# ---------------------------------------------------------------------------
# Sentence segmentation
# ---------------------------------------------------------------------------

_SEGMENTERS = threading.local()
# Cheap probe: with no boundary inside the text there is nothing to segment, so
# a single-sentence dictation never pays for the segmenter at all. CJK needs the
# whitespace to be optional because it runs sentences together without a space;
# requiring it elsewhere keeps "example.com" style text on the fast path.
_BREAK_CACHE: dict[str, re.Pattern[str]] = {}


def _internal_break_pattern(punctuation: Punctuation) -> re.Pattern[str]:
    key = punctuation.terminators + "|" + punctuation.join
    cached = _BREAK_CACHE.get(key)
    if cached is None:
        marks = re.escape(punctuation.terminators)
        gap = r"\s*" if punctuation.join == "" else r"\s+"
        cached = re.compile(rf"[{marks}]{gap}\S")
        _BREAK_CACHE[key] = cached
    return cached


def _segmenter(code: str) -> pysbd.Segmenter:
    cache = getattr(_SEGMENTERS, "cache", None)
    if cache is None:
        cache = {}
        _SEGMENTERS.cache = cache
    segmenter = cache.get(code)
    if segmenter is None:
        # Instances are cached per thread; pysbd keeps per-call state internally
        # and sharing one across threads is not worth the risk.
        segmenter = pysbd.Segmenter(language=code, clean=False)
        cache[code] = segmenter
    return segmenter


def _segment(text: str, punctuation: Punctuation) -> list[str]:
    if not _internal_break_pattern(punctuation).search(text):
        return [text]
    code = punctuation.segmentation_language
    if code in LANGUAGE_CODES:
        sentences = [str(sentence) for sentence in _segmenter(code).segment(text)]
        if sentences and "".join(sentences) == text:
            return sentences
    return _split_on_terminators(text, punctuation)


def _split_on_terminators(text: str, punctuation: Punctuation) -> list[str]:
    """Fallback for languages pysbd does not cover, such as Korean. It has no
    abbreviation knowledge, so it only splits on a terminator run."""
    boundary = re.compile(rf"[{re.escape(punctuation.terminators)}]+\s+")
    sentences: list[str] = []
    start = 0
    for match in boundary.finditer(text):
        sentences.append(text[start : match.end()])
        start = match.end()
    if start < len(text):
        sentences.append(text[start:])
    return sentences or [text]


# ---------------------------------------------------------------------------
# Styles
# ---------------------------------------------------------------------------

_FIRST_LETTER = re.compile(r"^([\"'“‘(\[]*)([^\W\d_])")


def apply_writing_style(text: str, style: str, language: str = "auto") -> str:
    """Format a local transcript without changing its words or meaning.

    Every style is presentation only: casing, spacing and sentence punctuation.
    No word is ever added, removed or substituted, and protected spans such as
    numbers, times, URLs, email addresses and contractions come back exactly as
    the model produced them.
    """
    if style == "raw":
        return text.strip()
    if style not in SUPPORTED_WRITING_STYLES:
        raise ValueError(f"Unsupported writing style: {style}")

    punctuation = _resolve_punctuation(language, text)
    masked, tokens = _protect(text)
    normalized = _normalize_spacing(masked, punctuation)

    if style == "clean":
        result = _ensure_terminator(normalized, punctuation)
    elif style == "formal":
        result = _formal(normalized, punctuation)
    elif style == "casual":
        result = _casual(normalized, punctuation)
    else:
        # Only the styles that rewrite sentence terminators need real
        # boundaries; getting them wrong turns "Dr. Smith" into "Dr! Smith".
        # Formal and casual leave terminators alone, so they skip the cost.
        sentences = _segment(normalized, punctuation)
        if style == "very_casual":
            result = _very_casual(sentences, punctuation)
        else:
            result = _excited(sentences, punctuation)

    if style == "very_casual":
        tokens = [token if _ADDRESS.match(token) else token.lower() for token in tokens]
    return _restore(result, tokens)


def _normalize_spacing(text: str, punctuation: Punctuation) -> str:
    result = re.sub(r"\s+", " ", text).strip()
    marks = re.escape(punctuation.terminators + punctuation.separator + ";:")
    return re.sub(rf"\s+([{marks}])", r"\1", result)


def _capitalize(text: str) -> str:
    return _FIRST_LETTER.sub(
        lambda match: match.group(1) + match.group(2).upper(),
        text,
        count=1,
    )


def _split_terminator(sentence: str, punctuation: Punctuation) -> tuple[str, str]:
    """Return the sentence body and its terminator, keeping an ellipsis with the
    body because it is deliberate rather than a sentence end."""
    body = sentence.strip()
    if body and body[-1] in punctuation.terminators and not body.endswith(".."):
        return body[:-1], body[-1]
    return body, ""


def _ensure_terminator(text: str, punctuation: Punctuation) -> str:
    if text and text[-1] not in punctuation.terminators:
        return text + punctuation.terminator
    return text


_SENTENCE_START_CACHE: dict[str, re.Pattern[str]] = {}


def _sentence_start_pattern(punctuation: Punctuation) -> re.Pattern[str]:
    cached = _SENTENCE_START_CACHE.get(punctuation.terminators)
    if cached is None:
        marks = re.escape(punctuation.terminators)
        cached = re.compile(rf"(^|[{marks}]\s*)([\"'“‘(\[]*)([^\W\d_])")
        _SENTENCE_START_CACHE[punctuation.terminators] = cached
    return cached


def _capitalize_sentence_starts(text: str, punctuation: Punctuation) -> str:
    """Safe without real segmentation: capitalising after an abbreviation is a
    no-op because the following word is already a capitalised name, and acronyms
    are masked before this runs."""
    return _sentence_start_pattern(punctuation).sub(
        lambda match: match.group(1) + match.group(2) + match.group(3).upper(),
        text,
    )


def _formal(text: str, punctuation: Punctuation) -> str:
    return _ensure_terminator(_capitalize_sentence_starts(text, punctuation), punctuation)


def _casual(text: str, punctuation: Punctuation) -> str:
    """Sentence structure is preserved; only a closing full stop is dropped, the
    way a dictated message is usually typed. A question mark or an exclamation
    carries meaning and stays."""
    result = _capitalize_sentence_starts(text, punctuation)
    # The empty-terminator guard is load-bearing, not defensive: Thai and Lao end
    # sentences with nothing at all, and `"text".endswith("")` is True while
    # `result[:-0]` is the empty string, so an unguarded drop erases the transcript.
    if (
        punctuation.terminator
        and result.endswith(punctuation.terminator)
        and not result.endswith("..")
    ):
        return result[: -len(punctuation.terminator)]
    return result


def _very_casual(sentences: list[str], punctuation: Punctuation) -> str:
    """Everything runs together in lower case. Joining with the clause separator
    is safe here precisely because nothing keeps its capital."""
    parts = []
    for index, sentence in enumerate(sentences):
        body, terminator = _split_terminator(sentence, punctuation)
        if not body:
            continue
        if index == len(sentences) - 1:
            parts.append(body)
        elif terminator in ("", punctuation.terminator):
            parts.append(body + punctuation.separator)
        else:
            # A question or an exclamation carries meaning worth keeping.
            parts.append(body + terminator)
    return _lower_outside_placeholders(punctuation.join.join(parts))


def _excited(sentences: list[str], punctuation: Punctuation) -> str:
    parts = []
    for sentence in sentences:
        body, terminator = _split_terminator(sentence, punctuation)
        if not body:
            continue
        if terminator == punctuation.question:
            parts.append(_capitalize(body) + terminator)
        else:
            parts.append(_capitalize(body) + punctuation.exclamation)
    return punctuation.join.join(parts)


def _lower_outside_placeholders(text: str) -> str:
    pieces: list[str] = []
    position = 0
    for match in _PLACEHOLDER.finditer(text):
        pieces.append(text[position : match.start()].lower())
        pieces.append(match.group(0))
        position = match.end()
    pieces.append(text[position:].lower())
    return "".join(pieces)
