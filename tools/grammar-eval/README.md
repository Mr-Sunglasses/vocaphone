# Grammar eval

The go/no-go spike for an optional, on-device "Fix grammar (English)" stage. It
scores the [MindType tagger v1.5](https://huggingface.co/Mindscend/mindtype-tagger-v1.5)
(Apache-2.0, 26.2M parameters, int8 ONNX) on dictation-style English, and
`infer.py` is the reference recipe the Android and iOS ports must match.
Nothing here ships in either app.

```bash
cd tools/grammar-eval
uv run --with-requirements requirements.txt python fetch.py         # ~28 MB, SHA-256 checked
uv run --with-requirements requirements.txt python eval.py ~/.cache/vocaphone/mindtype-tagger-v1.5 --compare
uv run --with-requirements requirements.txt python fixtures.py ~/.cache/vocaphone/mindtype-tagger-v1.5 --check
uv run --with-requirements requirements.txt python infer.py ~/.cache/vocaphone/mindtype-tagger-v1.5 "He don't know."
```

| File | What it is |
| --- | --- |
| `fetch.py` | Downloads the five pinned files at revision `a737fbc7…` and checks size and SHA-256 |
| `infer.py` | The reference recipe: tokenize, run, KEEP bias, guard, apply, repeat |
| `eval.py` | Scores `infer.py` on `dictation_en.jsonl` and writes `results.md` |
| `dictation_en.jsonl` | 337 hand-written lines: 174 correct, 163 with errors |
| `results.md` | Generated: every false positive, protected-span loss and miss |
| `fixtures.py` | Writes `assets/grammar/parity_fixtures.json` for both apps' tests |

## Decision: GO

| Configuration | Precision | Recall | F0.5 | Exact (errors) | False-positive rate (correct) | Protected-span damage | p50 ms | p95 ms |
|---|---|---|---|---|---|---|---|---|
| **shipped recipe** | **0.944** | **0.596** | **0.846** | **60.1%** | **0.0%** | **0** | **2.2** | **4.3** |
| no guard or protections, KEEP bias 2.0 | 0.927 | 0.596 | 0.835 | 59.5% | 1.7% | 0 | 2.2 | 4.4 |
| guard, KEEP bias 0 | 0.906 | 0.620 | 0.829 | 62.6% | 1.1% | 0 | 2.2 | 4.3 |
| guard, KEEP bias 3.0 | 0.960 | 0.567 | 0.843 | 57.1% | 0.0% | 0 | 2.2 | 4.3 |
| alignment: no `[BOS]` | 0.912 | 0.363 | 0.700 | 35.6% | 4.0% | 0 | 2.0 | 4.0 |
| alignment: first word without `Ġ` | 0.959 | 0.544 | 0.832 | 54.6% | 0.0% | 0 | 2.1 | 4.3 |
| alignment: last subtoken | 0.951 | 0.456 | 0.782 | 46.6% | 0.0% | 0 | 2.1 | 4.1 |
| protected spans fed as placeholders | 0.944 | 0.596 | 0.846 | 60.1% | 0.0% | 0 | 2.2 | 4.2 |

Gate: false positives ≤ 3% on correct sentences (0.0%), no protected-span
damage (0), and a real gain on the error set (98 of 163 fixed exactly, edit
precision 0.94). Precision and recall are over word-level edits
(`difflib` on the same word split the model uses); "exact" is whole-sentence.
Latency is one sentence through every pass on an Apple-silicon laptop CPU,
ONNX Runtime 1.31, two threads; timings move by a few tenths of a millisecond between runs.

Read the numbers with these caveats:

- **The set and the recipe have one author.** One guard rule (`too` is never
  replaced before punctuation or the end) was added after the eval showed
  `I want to come too.` → `to.`; without it the false-positive rate is 0.6%
  (1 of 174). There is no held-out set.
- **The guard is barely exercised here.** With the KEEP bias at 2.0 the model
  proposes 103 edits across the set and the guard vetoes only the `too` one.
  The rules are a safety net for inputs this set does not cover, not a source
  of the score.
- **It fixes agreement, articles and the common homophones, and little else.**
  `then/than` mid-sentence, `your/you're` before an adjective, verb forms after
  modals (`can sings`, `didn't came`), double negatives, pronoun case
  (`Me and him`) and most sound-alike content words (`whether`, `hole`,
  `right an email`) are left alone. It never produced a sentence worse than
  its input on the correct set. On the error set, 6 outputs differ from the
  expected fix: 3 are valid alternatives the metric counts as wrong
  (`I am going` for `I'm going`) and 3 are still wrong
  (`They're house` → `There house`, `over they're` → `over their`,
  `I no what you mean.` → `I have no what you mean.`). All are listed in
  `results.md`.
- **Phone latency is not measured yet.** A 45-word sentence takes about 7 ms
  here, and four of them about 30 ms. A long dictation on a slow phone CPU can
  approach the 150 ms budget, so the ports should spend that budget
  sentence by sentence and keep what finished, rather than discard all of it.

## The recipe

Nothing upstream publishes inference code. Each rule below was settled by
running the model.

**Model I/O.** Inputs `ids` and `mask`, int64 `[1, T]`; output `logits`,
float32 `[1, T, 15000]`, one row per token. `T` ≤ 160.

**Labels** (`labels.json`, a list of 15,000 strings). The prompt's `$KEEP` /
`$DELETE` / `$REPLACE_` / `$APPEND_` are wrong: they are `KEEP` (index 0),
`DELETE` (1), `REPLACE_<w>`, `APPEND_<w>`, and three case labels at 2–4,
`$CASE_CAP`, `$CASE_LOW`, `$CASE_UP`. `REPLACE_` targets keep their case
(`REPLACE_They're` and `REPLACE_they're` both exist).

**Words.** `\d+` (a `ProtectedSpans` placeholder), else a run of
letters and digits with inner apostrophes (`don't` is one word), else one
non-space character. Curly `’` is fed to the model as `'` (it has never seen
`’`: `He don’t know.` was left alone) and put back on the replacement.

**Alignment.** `[BOS]` (id 1), then each word encoded on its own as
`" " + word` with the byte-level BPE, the first word included, and the label
read at the word's first subtoken. There is no end token. A protected
placeholder is fed as the span it hides (`example.com`); this scored the same
as feeding the placeholder and reads as the sentence was said.

**Per word,** add 2.0 to the `KEEP` logit and take the argmax. The guard turns
anything else back into `KEEP` when:

- the word is a protected span, has a digit or a non-Latin character, is in the
  user's vocabulary, has a capital after its first letter (`iPhone`, `NASA`),
  or is capitalized mid-sentence (a name; `I` and `I'm` are not names);
- it is a preposition being replaced or deleted and the next word is
  capitalized, has a digit, is a protected span, or starts with `$ £ € # @`;
- it is `DELETE` on anything but `more most of the a an to is are`;
- it is a case label other than `$CASE_CAP` on a lowercase sentence start or
  on `i`, or `$CASE_UP` on `i` (the engine already cased the sentence);
- it is `APPEND_<w>` where `w` is not punctuation or one of
  `a an the to is are am was were be have has 's 'm 're 've 'll 'd`;
- it is `REPLACE_too` before punctuation or the end of the sentence;
- it is `REPLACE_<w>` and the pair is not: case-only, in `plausible_pairs.json`
  (314 `src→dst` strings), in the closed confusion sets in `infer.py`
  (articles, `be`/`have`/`do` forms, `their/there/they're`, `its/it's`,
  `your/you're`, `then/than`, `to/too/two`, `of/have`, …), or an edit distance
  ≤ 2 between words of four letters or more. Plain "distance ≤ 2" would let
  `at → in` through.

**Apply** the labels, keep each word's original leading whitespace, give
appended punctuation and `'`-clitics no space, recapitalize a sentence start
that a replacement lowercased, and lowercase a capitalized replacement
mid-sentence.

**Passes.** Split into sentences at `.`, `!` or `?` followed by whitespace,
mask protected spans once for the whole text, and run each sentence up to 3
times, stopping after a pass that changes nothing. A sentence longer than 150
tokens is cut into chunks at word boundaries. If the output has no letters,
return the input.

## Parity fixtures

`assets/grammar/parity_fixtures.json` holds 41 cases and 29 tokenizer-only
words. For each pass of each sentence it records the words, the token ids, the
first-subtoken positions, the label after the bias and the label the guard
allowed, then the final text. The ports should match `ids` exactly, apply
`chosen` to reach `output` without the model, and, in an opt-in test with the
real model, reproduce `labels`. ONNX Runtime versions differ (1.31 here, 1.28
in the apps), so an end-to-end mismatch in `labels` is worth a look before it
is called a bug. Regenerate with `fixtures.py` and commit both together when
`infer.py` changes.
