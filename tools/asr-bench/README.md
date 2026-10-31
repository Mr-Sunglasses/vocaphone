# ASR accuracy benchmark

Word error rate (WER) for the pinned on-device models on real speech, through
each app's own decode path. `just ios model-test` and `just android model-test`
decode synthesized speech and catch a broken decoder. This measures whether a
change made dictation more or less accurate.

```bash
just ios accuracy parakeet-tdt-ctc-110m-en                  # every set, both paths
just ios accuracy openai_whisper-small_216MB mytag "librispeech-long" "file" 10
just android accuracy small-q8_0 crop-off "librispeech-clean librispeech-other" off

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

| File | What it is |
| --- | --- |
| `prepare.py` | Downloads and builds the sets. Standard library and `ffmpeg` |
| `score.py` | WER / CER tables, run comparison, worst clips |
| `requirements.txt` | `jiwer` and `whisper-normalizer`, pinned |
| `ios/VocaPhoneTests/AccuracyBenchmarkTests.swift` | Decodes on iOS; skipped unless `just ios accuracy` sets it up |
| `android/.../local/WhisperAccuracyBenchmarkTest.kt` | Decodes on Android; skipped unless `just android accuracy` sets it up |

Baseline numbers live in [docs/local-model-review.md](../../docs/local-model-review.md).
