# ASR accuracy benchmark

Word error rate (WER) for the pinned on-device models on real speech, through
each app's own decode path. `just ios model-test` and `just android model-test`
decode synthesized speech and catch a broken decoder. This measures whether a
change made dictation more or less accurate.

```bash
just ios accuracy parakeet-tdt-ctc-110m-en                  # every set, both paths
just ios accuracy openai_whisper-small_216MB mytag "librispeech-long" "file" 10
just android accuracy small-q8_0 crop-off "librispeech-clean librispeech-other" off

# Names and jargon, decoded with the custom vocabulary a user would have entered
just ios accuracy qwen3-asr-0.6b vocab "vocab-en"
just android accuracy small-q8_0 vocab "vocab-en"

# Ordinary speech from a user with a long vocabulary: every LibriSpeech clip
# decoded with all 56 vocab-en terms (the last argument; iOS only)
just ios accuracy parakeet-unified-0.6b-en all56 "librispeech-clean librispeech-other" "file streamed" "" balanced vocab-en

# The same sentences with no vocabulary, then with the text around the cursor
just ios accuracy qwen3-asr-0.6b ctx-none "vocab-en" "file streamed" "" fast "" "" none
just ios accuracy qwen3-asr-0.6b ctx-context "vocab-en" "file streamed" "" fast "" "" context
just android accuracy small-q8_0 ctx-context "vocab-en" model fast "" "" context

# Score again, compare two runs, or read the worst clips
uv run --with-requirements tools/asr-bench/requirements.txt python tools/asr-bench/score.py --tag baseline --compare mytag
uv run --with-requirements tools/asr-bench/requirements.txt python tools/asr-bench/score.py --tag baseline \
    --worst parakeet-tdt-ctc-110m-en librispeech-long file
```

Not a CI gate. A run takes minutes for Parakeet 110M and longer for Whisper in
the simulator. The simulator and the host JVM run on the Mac's CPU, so the
real-time factor (RTF) column says nothing about a phone. WER does carry over.

## Sets

`prepare.py` downloads the public test sets into `~/.cache/vocaphone/asr-bench`
(override with `VOCA_ASR_BENCH_DIR`), checks each archive's SHA-256, and writes
an evenly spread, deterministic subset as the 16 kHz mono float WAV the apps
capture. The recipes run it when a set is missing. Nothing is checked in:
AGENTS.md keeps recordings and transcripts out of the repository.

| Set | Clips | Source | Measures |
| --- | --- | --- | --- |
| `librispeech-clean` | 200 | LibriSpeech test-clean (CC BY 4.0) | Read English, quiet |
| `librispeech-other` | 200 | LibriSpeech test-other | Read English, harder speakers |
| `librispeech-long` | 24, 45–90 s | Consecutive utterances of one chapter, half clean, half other | Windowing and chunk seams |
| `fleurs-hi` | 200 | FLEURS Hindi test (CC BY 4.0) | Hindi in Devanagari |
| `vocab-en` | 50, 3.5–6 s | [`vocab_en.json`](vocab_en.json), spoken by macOS `say` | Names, product names, code identifiers and jargon, with a custom vocabulary |

`vocab-en` is the one set that exercises custom vocabulary: LibriSpeech and
FLEURS have almost no names or jargon, so they cannot show a vocabulary change
helping. They can show one hurting: the iOS recipe's last argument,
`background`, set to `vocab-en`, decodes every clip that has no vocabulary of
its own with all 56 terms, which is what a user with a long list meets when
they dictate something unrelated to it. Results record it, so a run cannot be
resumed under the other setting. Each sentence ("Ask Siddharth to rotate the PostgreSQL
password and update Tailscale") is spoken by one of six stock English voices
(US, UK, Australian, Irish, Indian, South African), the way a person would say
it: "postgres Q L", "cube control" for `kubectl`. Each clip carries the
vocabulary a user would have entered: the terms it uses and four others from
the same 56-term list, in an order fixed by the clip id. The runners pass that
list to the app as its custom vocabulary, so it reaches the decoder (Whisper's
prompt, Qwen3-ASR's and Parakeet Unified's hotwords) and the finishing funnel
exactly as Settings would. Synthetic speech is cleaner than a person; read the set for the
difference a change makes, not as a phone's accuracy on names.

The last argument of each recipe, `hints`, says what a clip is decoded with:
`vocabulary` (the default) as above; `none`, nothing; or `context`, no
vocabulary but the terms `ContextTerms` takes from a text before the cursor, as
a keyboard dictation would (see [Text around the cursor](../../docs/architecture.md#text-around-the-cursor)).
That text is [`vocab_en_context.json`](vocab_en_context.json): for each
`vocab-en` sentence, an earlier message in the same thread, written the way a
person would (so some terms start a sentence, and `kubectl` and `npm` are not
there at all); for every other set, one unrelated message full of names, which
checks that a busy field costs nothing on speech that uses none of them. The
file is read by the runners directly, so editing it needs no new audio.

`prepare.py` checks `vocab_en.json` against a pinned SHA-256 and records the
macOS version and each clip's audio digest in `sets/vocab-en/source.json`:
`say` voices change between macOS releases, so compare two runs only on the
same audio. After editing the script, update the digest and delete
`sets/vocab-en`.

LibriSpeech is read audiobook speech with no fillers or false starts. It
penalises the speech-repair stage for every correct word it deletes and never
credits it for a real stutter removed. Read the raw and finished columns with
that in mind.

## Paths

| Path | iOS | Android |
| --- | --- | --- |
| `file` | A finished recording: levelled, then Whisper's VAD windows or sherpa's silence chunks | whisper.cpp on the levelled recording |
| `streamed` | A dictation fed 100 ms at a time to the incremental session, then finished as `RecordingCoordinator` does | — |

Android models appear as `android-<id>` in the tables.

## Scoring

`score.py` scores `raw` (the model's text) and `finished` (what the keyboard
types after repair, digits and styling). English uses the Whisper English
normaliser, as the Open ASR Leaderboard does, so casing, punctuation and
spelled-out numbers are not errors. Hindi keeps its vowel signs, which
Whisper's basic normaliser strips, and also reports character error rate
(CER).

Each record also carries `unsure`: the words the engine decoded below 0.6
probability every time it heard them, which finishing uses to decide whether
ordinary words may be a misheard custom word, or `null` for an engine that
reports no confidence (see `RecognitionConfidence`).

To check that custom-word correction leaves ordinary speech alone, give a run
a control vocabulary. Clips without a vocabulary of their own are then also
finished with it, as `finishedVocabulary`, from the same decode, and `score.py`
prints the WER with and without it and how many clips it changed:

```bash
python3 -c 'import json; print("\n".join(t["term"] for t in json.load(open("tools/asr-bench/vocab_en.json"))["terms"]))' \
    > ~/.cache/vocaphone/asr-bench/vocab-en-terms.txt
just ios accuracy parakeet-unified-0.6b-en control "librispeech-clean librispeech-other" file 50 \
    balanced ~/.cache/vocaphone/asr-bench/vocab-en-terms.txt
just android accuracy small-q8_0 control "librispeech-clean librispeech-other" model balanced 50 \
    ~/.cache/vocaphone/asr-bench/vocab-en-terms.txt
```

`vocab-en` adds **term accuracy**: of every use of a vocabulary term in the
reference, the share the text spells exactly, case and all. "Postgres QL",
"postgresql" and "Tail scale" are misses. WER barely moves when one word in
twelve is a name, and its normaliser forgives the casing that makes "GitHub"
right, so term accuracy is the column to read for vocabulary work. `--worst`
lists the terms each clip missed.

| File | What it is |
| --- | --- |
| `prepare.py` | Downloads and builds the sets. Standard library and `ffmpeg`; `say` for `vocab-en` |
| `vocab_en.json` | The `vocab-en` sentences and the 56-term vocabulary |
| `vocab_en_context.json` | The text around the cursor for `hints=context` |
| `vocab.py` | Term matching shared by `prepare.py` and `score.py` |
| `score.py` | WER / CER / term accuracy tables, run comparison, worst clips |
| `requirements.txt` | `jiwer` and `whisper-normalizer`, pinned |
| `ios/VocaPhoneTests/AccuracyBenchmarkTests.swift` | Decodes on iOS; skipped unless `just ios accuracy` sets it up |
| `android/.../local/WhisperAccuracyBenchmarkTest.kt` | Decodes on Android; skipped unless `just android accuracy` sets it up |

Baseline numbers live in [docs/local-model-review.md](../../docs/local-model-review.md).
