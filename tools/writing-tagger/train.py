#!/usr/bin/env python3
"""Trains Writing check's part-of-speech tagger and writes assets/keyboard/en-pos.bin.

    python3 train.py DATA_DIR            # train, report accuracy, write the model
    python3 train.py DATA_DIR --check    # retrain and fail if the checked-in model differs

DATA_DIR holds the pinned UD English EWT files (`fetch.py` downloads them).
The treebank is CC BY-SA 4.0, and so is the model trained from it: see
`assets/keyboard/en-pos.LICENSE`.
Training is deterministic: a fixed seed, a fixed number of passes, and the
same output bytes every run.

The treebank is edited and grammatical, and Writing check tags what people
type, so every sentence is also seen as people type it: lower case, without
its final full stop, and with one verb put in the wrong agreement or form
("the kids plays", "did went"), tagged as what it now is. Without that last
one the tagger calls the very mistakes the agreement checks look for nouns.
"""

from __future__ import annotations

import argparse
import random
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "grammar-eval"))

from postag import START, Model, context_of, features, fnv, normalize, shape  # noqa: E402
from writing_text import tokenize  # noqa: E402

HERE = Path(__file__).parent
OUT = HERE.parent.parent / "assets" / "keyboard" / "en-pos.bin"

SEED = 7
PASSES = 6
# Averaged weights are scaled by this and rounded to int16; anything that
# rounds to zero is dropped, which is most of the model.
SCALE = 24
# Weights this small or smaller are dropped after scaling: most of the file, little of the accuracy.
PRUNE = 6
# A word seen this often with one tag at least this share of the time is
# tagged from a table, without features.
TAGDICT_MIN = 20
TAGDICT_SHARE = 0.985
# A joined tag ("VBP+RB") seen fewer times than this falls back to its first part.
JOINED_MIN = 8


# ── reading the treebank ─────────────────────────────────────────────────

def read_conllu(path: Path):
    """Sentences as lists of surface tokens: (text, space_after, [(xpos, lemma)])."""
    sentence, ranges = [], {}
    for line in path.read_text(encoding="utf-8").splitlines() + [""]:
        if not line:
            if sentence:
                yield sentence
            sentence, ranges = [], {}
            continue
        if line.startswith("#"):
            continue
        cols = line.split("\t")
        ident = cols[0]
        if "." in ident:
            continue  # empty node
        space = "SpaceAfter=No" not in cols[9]
        if "-" in ident:
            a, b = (int(x) for x in ident.split("-"))
            sentence.append([cols[1], space, []])
            for k in range(a, b + 1):
                ranges[k] = len(sentence) - 1
            continue
        k = int(ident)
        if k in ranges:
            sentence[ranges[k]][2].append((cols[4], cols[2]))
        else:
            sentence.append([cols[1], space, [(cols[4], cols[2])]])


def retokenize(surface):
    """The sentence as Writing check splits it: (words, tags, lemmas or None)."""
    text, spans = "", []
    for word, space, analysis in surface:
        spans.append((len(text), len(text) + len(word), analysis))
        text += word + (" " if space else "")
    words, tags, lemmas = [], [], []
    for tok in tokenize(text):
        covering = [a for (s, e, a) in spans if s < tok.end and tok.start < e]
        if not covering:
            continue
        if not tok.is_word:
            whole = [a for (s, e, a) in spans if s == tok.start and e == tok.end]
            tag = whole[0][0][0] if whole and len(whole[0]) == 1 else ("HYPH" if tok.text in "-‐‑" else "NFP")
            words.append(tok.text)
            tags.append(tag)
            lemmas.append(None)
            continue
        parts = [x for a in covering for x in a]
        whole_one = len(covering) == 1 and len(parts) == 1
        tags.append("+".join(p[0] for p in parts) if len(covering) == 1 else covering[0][0][0])
        lemmas.append(parts[0][1] if whole_one else None)
        words.append(tok.text)
    return words, tags, lemmas


# ── making the treebank look typed ───────────────────────────────────────

IRREGULAR_THIRD = {"be": "is", "have": "has", "do": "does", "go": "goes"}
PLURAL_BE = {"is": "are", "was": "were", "has": "have", "does": "do"}
SINGULAR_BE = {v: k for k, v in PLURAL_BE.items()} | {"am": "is"}


def third(lemma: str) -> str:
    if lemma in IRREGULAR_THIRD:
        return IRREGULAR_THIRD[lemma]
    if lemma.endswith("y") and len(lemma) > 1 and lemma[-2] not in "aeiou":
        return lemma[:-1] + "ies"
    if lemma.endswith(("s", "x", "z", "ch", "sh", "o")):
        return lemma + "es"
    return lemma + "s"


def corrupt(words, tags, lemmas, past, rng):
    """One verb in the wrong agreement or form, tagged as what it now is; None if there is none to change."""
    options = []
    for i, (w, t, l) in enumerate(zip(words, tags, lemmas)):
        if l is None or not w.isalpha():
            continue
        lw = w.lower()
        if t == "VBZ":
            new = PLURAL_BE.get(lw, l if l != "be" else "are")
            if new != lw:
                options.append((i, new, "VBP"))
        elif t == "VBP":
            new = SINGULAR_BE.get(lw, third(l))
            if new != lw:
                options.append((i, new, "VBZ"))
        elif t == "VB" and i > 0 and tags[i - 1] in ("MD", "TO"):
            options.append((i, third(l), "VBZ"))
        elif t == "VB" and i > 0 and words[i - 1].lower() in ("did", "didn't", "does", "doesn't", "do", "don't") and l in past:
            options.append((i, past[l], "VBD"))
        elif t == "VBD" and lw in ("was", "were"):
            options.append((i, "were" if lw == "was" else "was", "VBD"))
    if not options:
        return None
    i, new, tag = rng.choice(options)
    if words[i][0].isupper():
        new = new[0].upper() + new[1:]
    words, tags = list(words), list(tags)
    words[i], tags[i] = new, tag
    return words, tags


def typed(words, tags, rng):
    words, tags = list(words), list(tags)
    if rng.random() < 0.5:
        words = [w.lower() for w in words]
    if rng.random() < 0.5 and words and words[-1] in (".", "!"):
        words, tags = words[:-1], tags[:-1]
    return words, tags


# ── training ─────────────────────────────────────────────────────────────

class Perceptron:
    def __init__(self):
        self.w = defaultdict(lambda: defaultdict(float))
        self.totals = defaultdict(float)
        self.stamps = defaultdict(int)
        self.i = 0

    def predict(self, feats, ntags):
        scores = [0.0] * ntags
        for f in feats:
            for t, v in self.w.get(f, {}).items():
                scores[t] += v
        best = 0
        for t in range(1, ntags):
            if scores[t] > scores[best]:
                best = t
        return best

    def update(self, truth, guess, feats):
        self.i += 1
        if truth == guess:
            return
        for f in feats:
            ws = self.w[f]
            for t, d in ((truth, 1.0), (guess, -1.0)):
                key = (f, t)
                self.totals[key] += (self.i - self.stamps[key]) * ws.get(t, 0.0)
                self.stamps[key] = self.i
                ws[t] = ws.get(t, 0.0) + d

    def averaged(self):
        out = {}
        for f, ws in self.w.items():
            row = {}
            for t, v in ws.items():
                key = (f, t)
                total = self.totals[key] + (self.i - self.stamps[key]) * v
                avg = total / self.i
                if avg:
                    row[t] = avg
            if row:
                out[f] = row
        return out


def train(sentences, tag_index, tagdict_words):
    model = Perceptron()
    n = len(tag_index)
    tag_list = list(tag_index)
    rng = random.Random(SEED)
    data = list(sentences)
    for it in range(PASSES):
        right = total = 0
        for words, tags in data:
            context = context_of(words)
            shapes = [shape(w) for w in words]
            p1, p2 = START
            for i, gold in enumerate(tags):
                g = tag_index[gold]
                fixed = tagdict_words.get(context[i + 2])
                if fixed is not None:
                    guess = fixed
                else:
                    feats = features(i, context, shapes, p1, p2)
                    guess = model.predict(feats, n)
                    model.update(g, guess, feats)
                right += guess == g
                total += 1
                p2, p1 = p1, tag_list[guess]
        rng.shuffle(data)
        print(f"pass {it + 1}: {right / total:.4f}", file=sys.stderr)
    return model.averaged()


def quantize(averaged, tags, tagdict_words):
    rows = {}
    for f, ws in averaged.items():
        q = sorted((t, max(-32768, min(32767, round(v * SCALE)))) for t, v in ws.items())
        q = [(t, v) for t, v in q if abs(v) > PRUNE]
        if q:
            rows[fnv(f)] = q
    hashes = sorted(rows)
    assert len(hashes) == len(rows), "feature hash collision"
    offsets, entries = [0], []
    for h in hashes:
        entries += rows[h]
        offsets.append(len(entries))
    tagdict = {fnv("w " + w): t for w, t in tagdict_words.items()}
    assert len(tagdict) == len(tagdict_words), "tagdict hash collision"
    return Model(tags, tagdict, hashes, offsets, entries)


def accuracy(model: Model, sentences) -> float:
    right = total = 0
    for words, tags in sentences:
        got = model.tag(words)
        right += sum(a == b for a, b in zip(got, tags))
        total += len(tags)
    return right / total


def load(data_dir: Path, name: str):
    out = []
    for s in read_conllu(data_dir / f"en_ewt-ud-{name}.conllu"):
        words, tags, lemmas = retokenize(s)
        if words:
            out.append((words, tags, lemmas))
    return out


def build(data_dir: Path) -> tuple[bytes, str]:
    train_set, dev_set = load(data_dir, "train"), load(data_dir, "dev")
    joined = Counter(t for _, tags, _ in train_set for t in tags if "+" in t)
    keep = {t for t, c in joined.items() if c >= JOINED_MIN}

    def fold(tags):
        return [t if "+" not in t or t in keep else t.split("+")[0] for t in tags]

    train_set = [(w, fold(t), l) for w, t, l in train_set]
    dev_set = [(w, fold(t), l) for w, t, l in dev_set]

    past = {}
    counts = Counter((l, w.lower()) for words, tags, lemmas in train_set
                     for w, t, l in zip(words, tags, lemmas) if t == "VBD" and l)
    for (l, w), c in sorted(counts.items(), key=lambda x: (-x[1], x[0])):
        past.setdefault(l, w)

    rng = random.Random(SEED)
    examples = []
    for words, tags, lemmas in train_set:
        examples.append((words, tags))
        examples.append(typed(words, tags, rng))
        bad = corrupt(words, tags, lemmas, past, rng)
        if bad:
            examples.append(typed(*bad, rng))

    tags = sorted({t for _, ts in examples for t in ts})
    tag_index = {t: i for i, t in enumerate(tags)}

    seen = defaultdict(Counter)
    for words, ts, _ in train_set:
        for w, t in zip(words, ts):
            seen[normalize(w)][t] += 1
    tagdict_words = {}
    for w, c in seen.items():
        t, k = c.most_common(1)[0]
        n = sum(c.values())
        if n >= TAGDICT_MIN and k / n >= TAGDICT_SHARE and not w.startswith("!"):
            tagdict_words[w] = tag_index[t]

    averaged = train(examples, tag_index, tagdict_words)
    model = quantize(averaged, tags, tagdict_words)
    blob = model.to_bytes()
    assert Model.from_bytes(blob).hashes == model.hashes

    dev_plain = [(w, t) for w, t, _ in dev_set]
    rng = random.Random(SEED + 1)
    dev_lower = [([x.lower() for x in w], t) for w, t in dev_plain]
    dev_bad = [b for b in (corrupt(w, t, l, past, rng) for w, t, l in dev_set) if b]
    report = (f"{len(tags)} tags, {len(model.tagdict)} table words, {len(model.hashes)} features, "
              f"{len(model.entries)} weights, {len(blob) / 1e6:.2f} MB\n"
              f"dev accuracy: as written {accuracy(model, dev_plain):.4f}, "
              f"lower case {accuracy(model, dev_lower):.4f}, "
              f"one verb wrong {accuracy(model, dev_bad):.4f}")
    return blob, report


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("data_dir", type=Path)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args()
    blob, report = build(args.data_dir)
    print(report)
    if args.check:
        if not args.out.exists() or args.out.read_bytes() != blob:
            sys.exit(f"{args.out} is stale; run train.py")
        print(f"{args.out.name} is current")
        return
    args.out.write_bytes(blob)


if __name__ == "__main__":
    main()
