#!/usr/bin/env python3
"""Reference inference for the MindType v2.0 grammar tagger.

This is the recipe both apps port. Nothing upstream publishes inference code,
so every rule below was settled by running the model; README.md records how.

    text ─ split sentences ─┬─ mask protected spans ─ words ─ tokens ─ ONNX
                            │      ↑                                    │
                            │      └──────── up to 3 passes ────────────┤
                            │                                           ↓
                            └─────────── restore ─ join ←─ edits ←─ guard

Usage:
    python3 infer.py MODEL_DIR "He don't know."
"""

from __future__ import annotations

import json
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

# "Balanced". v2.0 is tuned for 3 (its card's default); 4 is "Only sure fixes".
KEEP_BIAS = 3.0
SURE_KEEP_BIAS = 4.0
# A Writing check the user asked for, where every edit is a card they accept or
# dismiss: more fixes for a few more wrong ones. Never dictation.
THOROUGH_KEEP_BIAS = 1.0
MAX_PASSES = 3
# The model's position table holds 160; one goes to [BOS].
MAX_TOKENS = 150
BOS_ID = 1
KEEP, DELETE = 0, 1

# The same spans `ProtectedSpans` masks in both apps (URLs, emails, bare
# domains, decimals and times, ordinals, dotted initialisms). Kept in step with
# android/.../core/ProtectedSpans.kt by hand.
_HOSTNAME = r"\b(?:[\w-]+\.)+(?:[a-z]{2,24}|[A-Z]{2,24})\b"
_PATH = r"""(?:/[^\s]*[^\s.,;:!?"“”'\)\]])?"""
PROTECTED = re.compile(
    r"""((?i:https?)://[^\s]+[^\s.,;:!?"“”'\)\]]"""
    r"|[\w.+-]+@(?:[\w-]+\.)+[A-Za-z]{2,}"
    rf"|{_HOSTNAME}{_PATH}"
    r"|\d+(?:[.,:/]\d+)+"
    r"|\d+(?i:st|nd|rd|th)\b"
    r"|(?:[A-Za-z]\.){2,})"
)
PLACEHOLDER = re.compile("(\\d+)")

# A word is a run of letters/digits with inner apostrophes ("don't", "it's"),
# a placeholder, or one punctuation mark. This is the unit the model labels.
WORD = re.compile(r"\d+|[^\W_]+(?:['’][^\W_]+)*|\S")

LATIN_WORD = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*")

PREPOSITIONS = frozenset(
    "about above across after against along around at before behind below "
    "beside between by down during for from in inside into near of off on "
    "onto out over past since through till to toward towards under until up "
    "upon with within without".split()
)
GUARD_NEXT = frozenset("$£€#@")

# Closed classes the guard always lets through even past the edit-distance cap:
# articles, be/have/do agreement, and the homophones speech engines mix up.
CONFUSION_SETS = [
    {"a", "an", "the"},
    {"is", "are", "am", "was", "were", "be", "been", "being"},
    {"has", "have", "had"},
    {"do", "does", "did", "done"},
    {"don't", "doesn't", "didn't"},
    {"isn't", "aren't", "wasn't", "weren't"},
    {"hasn't", "haven't"},
    {"their", "there", "they're"},
    {"its", "it's"},
    {"your", "you're"},
    {"whose", "who's"},
    {"were", "we're", "where"},
    {"then", "than"},
    {"to", "too", "two"},
    {"of", "have"},
    {"lose", "loose"},
    {"affect", "effect"},
    {"accept", "except"},
    {"fewer", "less"},
    {"lie", "lay", "lying", "laying"},
    {"me", "i"},
    {"him", "he"},
    {"her", "she"},
    {"them", "they"},
    {"us", "we"},
]
CONFUSION = {(a, b) for s in CONFUSION_SETS for a in s for b in s if a != b}

# APPEND is the riskiest edit: it adds a word that was never spoken. Only short
# function words that speech genuinely drops are allowed in.
APPENDABLE = frozenset(
    "a an the to is are am was were be have has 's 'm 're 've 'll 'd".split()
)
PUNCT = frozenset(".,!?;:")


def edit_distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


@dataclass
class Word:
    text: str
    space: str  # whitespace before the word in the original
    protected: bool = False


@dataclass
class Decision:
    word: str
    label: str  # the raw argmax after bias
    chosen: str  # what the guard allowed (KEEP when vetoed)


@dataclass
class PassTrace:
    words: list[str]
    ids: list[int]
    starts: list[int]
    decisions: list[Decision]


@dataclass
class Result:
    output: str
    passes: list[list[PassTrace]] = field(default_factory=list)  # per sentence
    millis: float = 0.0


class Tagger:
    def __init__(self, model_dir: Path, keep_bias: float = KEEP_BIAS,
                 guard: bool = True, protect_names: bool = True,
                 alignment: str = "bos-space-first", feed_spans: bool = True):
        model_dir = Path(model_dir)
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 2
        self.session = ort.InferenceSession(str(model_dir / "mindtype_tagger.onnx"), opts)
        self.tokenizer = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
        self.labels: list[str] = json.loads((model_dir / "labels.json").read_text())
        pairs = json.loads((model_dir / "plausible_pairs.json").read_text())
        self.pairs = {tuple(p.split("→")) for p in pairs}
        self.keep_bias = keep_bias
        self.guard = guard
        self.protect_names = protect_names
        # The winning rule is the default; the others are kept for eval.py's
        # comparison table. See README.md, "Alignment".
        self.bos = "nobos" not in alignment
        self.lead_space = "nospace" not in alignment
        self.read_last = alignment.endswith("-last")
        self.feed_spans = feed_spans

    # ── tokenization ────────────────────────────────────────────────────

    def encode_word(self, word: str, first: bool = False) -> list[int]:
        # Every word, the first included, is encoded with a leading space:
        # the label is read at that Ġ-prefixed first subtoken.
        prefix = " " if self.lead_space or not first else ""
        return self.tokenizer.encode(prefix + word, add_special_tokens=False).ids

    def encode(self, words: list[str]) -> tuple[list[int], list[int]]:
        ids, starts = ([BOS_ID] if self.bos else []), []
        for i, w in enumerate(words):
            piece = self.encode_word(w, first=i == 0)
            starts.append(len(ids) + (len(piece) - 1 if self.read_last else 0))
            ids.extend(piece)
        return ids, starts

    # ── one pass ────────────────────────────────────────────────────────

    def logits(self, ids: list[int]) -> np.ndarray:
        a = np.array([ids], dtype=np.int64)
        return self.session.run(None, {"ids": a, "mask": np.ones_like(a)})[0][0]

    def model_text(self, word: Word, spans: list[str]) -> str:
        """What the model reads for a word.

        A placeholder is shown as the span it hides, so "at example.com" reads
        as it was said; the guard still freezes it. Curly apostrophes become
        straight ones: the training text had none, and "don’t" is otherwise
        three unknown pieces the model leaves alone.
        """
        m = PLACEHOLDER.fullmatch(word.text)
        if m and self.feed_spans:
            return spans[int(m.group(1))]
        return word.text.replace("’", "'")

    def tag(self, words: list[Word], start: int, end: int, vocabulary: frozenset[str],
            spans: list[str] = ()) -> PassTrace:
        """Runs words[start:end] through the model. The guard sees the whole
        sentence, so a name or a preposition at a chunk's edge keeps the
        protection it has anywhere else."""
        texts = [self.model_text(w, spans) for w in words[start:end]]
        ids, starts = self.encode(texts)
        lg = self.logits(ids)
        decisions = []
        for i, pos in enumerate(starts):
            row = lg[pos].astype(np.float64)
            row[KEEP] += self.keep_bias
            label = self.labels[int(row.argmax())]
            chosen = self.allow(words, start + i, label, vocabulary) if self.guard else label
            decisions.append(Decision(texts[i], label, chosen))
        return PassTrace(texts, ids, starts, decisions)

    # ── the guard ───────────────────────────────────────────────────────

    def frozen(self, words: list[Word], i: int, vocabulary: frozenset[str]) -> bool:
        w = words[i]
        if w.protected:
            return True
        if not LATIN_WORD.fullmatch(w.text):
            return w.text not in PUNCT  # digits, symbols, other scripts
        if w.text.lower().replace("’", "'") in vocabulary:
            return True
        if self.protect_names and any(c.isupper() for c in w.text[1:]):
            return True  # "iPhone", "McDonald", "NASA"
        if self.protect_names and w.text[0].isupper() and not sentence_start(words, i):
            return not is_pronoun_i(w.text)  # a name mid-sentence
        return False

    def allow(self, words: list[Word], i: int, label: str, vocabulary) -> str:
        if label == "KEEP":
            return label
        if self.frozen(words, i, vocabulary):
            return "KEEP"
        src = words[i].text
        nxt = words[i + 1].text if i + 1 < len(words) else ""
        if src.lower() in PREPOSITIONS and label != "KEEP" and not label.startswith("APPEND_"):
            if nxt and (nxt[0].isupper() or any(c.isdigit() for c in nxt)
                        or nxt[0] in GUARD_NEXT or PLACEHOLDER.fullmatch(nxt)):
                return "KEEP"
        # "come too." → "come to." is the one swap the model makes on correct
        # text in the eval set; a sentence cannot end on the preposition.
        if label.startswith("REPLACE_") and src.lower() == "too" and (not nxt or nxt in PUNCT):
            return "KEEP"
        if label == "DELETE":
            return label if src.lower() in {"more", "most", "of", "the", "a", "an", "to", "is", "are"} else "KEEP"
        if label.startswith("$CASE_"):
            # ASR already cased the sentence; only "i" → "I" and a lowercase
            # sentence start are worth trusting.
            if label == "$CASE_CAP" and src.islower() and (sentence_start(words, i) or src == "i"):
                return label
            if label == "$CASE_UP" and src == "i":
                return label
            return "KEEP"
        if label.startswith("APPEND_"):
            return label if label[7:].lower() in APPENDABLE or label[7:] in PUNCT else "KEEP"
        if label.startswith("REPLACE_"):
            dst = label[8:]
            if self.plausible(src, dst):
                return label
            return "KEEP"
        return "KEEP"

    def plausible(self, src: str, dst: str) -> bool:
        a, b = src.lower().replace("’", "'"), dst.lower()
        if a == b:
            return True  # a case-only replace, e.g. "their" → "They're" at start
        if (a, b) in self.pairs or (a, b) in CONFUSION:
            return True
        if not LATIN_WORD.fullmatch(dst):
            return False
        # Spelling-sized edits on content words. Short words are left to the
        # closed classes above: "at" → "in" is distance 2 and nearly always wrong.
        return min(len(a), len(b)) >= 4 and edit_distance(a, b) <= 2

    # ── apply ───────────────────────────────────────────────────────────

    def apply(self, words: list[Word], decisions: list[Decision]) -> list[Word]:
        out: list[Word] = []
        for i, (w, d) in enumerate(zip(words, decisions)):
            label = d.chosen
            if label == "KEEP":
                out.append(w)
            elif label == "DELETE":
                continue
            elif label == "$CASE_CAP":
                out.append(Word(w.text[0].upper() + w.text[1:], w.space))
            elif label == "$CASE_LOW":
                out.append(Word(w.text.lower(), w.space))
            elif label == "$CASE_UP":
                out.append(Word(w.text.upper(), w.space))
            elif label.startswith("REPLACE_"):
                dst = match_case(w.text, label[8:], sentence_start(words, i))
                if "’" in w.text:
                    dst = dst.replace("'", "’")
                out.append(Word(dst, w.space))
            elif label.startswith("APPEND_"):
                out.append(w)
                add = label[7:]
                out.append(Word(add, "" if add in PUNCT or add.startswith("'") else " "))
        if out and words and out[0].space != words[0].space:
            out[0] = Word(out[0].text, words[0].space, out[0].protected)
        # A deleted or replaced first word: keep the sentence capitalized.
        if out and words and words[0].text[:1].isupper() and out[0].text[:1].islower() \
                and not out[0].protected:
            out[0] = Word(out[0].text[0].upper() + out[0].text[1:], out[0].space)
        return out

    # ── the whole stage ─────────────────────────────────────────────────

    def correct(self, text: str, vocabulary: frozenset[str] = frozenset()) -> Result:
        start = time.perf_counter()
        # Apostrophes compared straight, as the model reads them: a word saved
        # as "don't" also keeps "don’t".
        vocabulary = frozenset(v.lower().replace("’", "'") for v in vocabulary)
        tokens: list[str] = []

        def stash(m: re.Match) -> str:
            tokens.append(m.group(0))
            return f"{len(tokens) - 1}"

        masked = PROTECTED.sub(stash, text)
        result = Result(output="")
        pieces = []
        for lead, sentence in split_sentences(masked):
            fixed, traces = self.correct_sentence(sentence, vocabulary, tokens)
            pieces.append(lead + fixed)
            result.passes.append(traces)
        out = PLACEHOLDER.sub(lambda m: tokens[int(m.group(1))], "".join(pieces))
        if not any(c.isalpha() for c in out):
            out = text
        result.output = out
        result.millis = (time.perf_counter() - start) * 1000
        return result

    def correct_sentence(self, sentence: str, vocabulary,
                         spans: list[str] = ()) -> tuple[str, list[PassTrace]]:
        words = split_words(sentence)
        if not words or not any(LATIN_WORD.search(w.text) for w in words):
            return sentence, []
        traces = []
        for _ in range(MAX_PASSES):
            chosen = ["KEEP"] * len(words)
            for start, end in self.chunk(words, spans):
                if end - start == 1 and self.oversized(words[start], spans):
                    continue  # one word longer than the model can read: leave it
                trace = self.tag(words, start, end, vocabulary, spans)
                traces.append(trace)
                chosen[start:end] = [d.chosen for d in trace.decisions]
            new = self.apply(words, [Decision(w.text, c, c) for w, c in zip(words, chosen)])
            changed = [w.text for w in new] != [w.text for w in words]
            words = new
            if not changed:
                break
        trailing = sentence[len(sentence.rstrip()):]
        return "".join(w.space + w.text for w in words) + trailing, traces

    def oversized(self, word: Word, spans: list[str]) -> bool:
        return len(self.encode_word(self.model_text(word, spans))) > MAX_TOKENS

    def chunk(self, words: list[Word], spans: list[str] = ()) -> list[tuple[int, int]]:
        """[start, end) word ranges of at most MAX_TOKENS tokens each. A word
        that alone is longer (a long URL fed as itself) gets a range of its
        own, which correct_sentence leaves untouched rather than overflow the
        model's 160 positions."""
        chunks, start, n = [], 0, 0
        for i, w in enumerate(words):
            k = len(self.encode_word(self.model_text(w, spans)))
            if i > start and n + k > MAX_TOKENS:
                chunks.append((start, i))
                start, n = i, 0
            if k > MAX_TOKENS:
                if i > start:
                    chunks.append((start, i))
                chunks.append((i, i + 1))
                start, n = i + 1, 0
                continue
            n += k
        if start < len(words):
            chunks.append((start, len(words)))
        return chunks


def split_words(sentence: str) -> list[Word]:
    words, pos = [], 0
    for m in WORD.finditer(sentence):
        words.append(Word(m.group(0), sentence[pos:m.start()],
                          protected=bool(PLACEHOLDER.fullmatch(m.group(0)))))
        pos = m.end()
    return words


SENTENCE_END = re.compile(r"((?<=[.!?])\s+)")


def split_sentences(text: str) -> list[tuple[str, str]]:
    """Returns (whitespace before, sentence) pairs that rejoin to `text`."""
    parts = SENTENCE_END.split(text)
    return [("" if i == 0 else parts[i - 1], parts[i]) for i in range(0, len(parts), 2)]


def sentence_start(words: list[Word], i: int) -> bool:
    j = i - 1
    while j >= 0 and words[j].text in "\"“'(":
        j -= 1
    return j < 0 or words[j].text in ".!?"


def is_pronoun_i(text: str) -> bool:
    return text == "I" or text.startswith(("I'", "I’"))


def match_case(src: str, dst: str, at_start: bool) -> str:
    if src.isupper() and len(src) > 1:
        return dst.upper()
    if src[:1].isupper() and (at_start or is_pronoun_i(src)):
        return dst[:1].upper() + dst[1:]
    if src[:1].islower() and dst[:1].isupper() and not is_pronoun_i(dst):
        return dst[:1].lower() + dst[1:]  # "their" → "They're" mid-sentence
    return dst


if __name__ == "__main__":
    tagger = Tagger(Path(sys.argv[1]))
    for line in sys.argv[2:]:
        r = tagger.correct(line)
        print(f"{r.millis:6.1f} ms  {line!r} → {r.output!r}")
