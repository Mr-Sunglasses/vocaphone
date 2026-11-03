# Local model review

Reviewed for PR #229 on 2026-09-19. Catalog size is a product trade-off, not an
accuracy leaderboard: published WER, an export's correctness, phone latency,
working memory, language coverage, and download size are separate evidence.

## Retained and retired models

| Choice | Assessment |
| --- | --- |
| Moonshine v2 Tiny and Base English | Remove both: retired onto Parakeet TDT-CTC 110M English, now the English starter and small English pick. Both Moonshine builds return empty transcripts for inputs of 9.4 s or more under the pinned runtime; the app windows up to 14 s. Even on shorter clips Base is less accurate. |
| Parakeet v2 English and v3 multilingual | Keep: English specialization and 25-language automatic recognition serve different needs. NVIDIA's GPU long-audio limits are not phone memory guarantees. |
| Canary 180M Flash | Keep: compact English/German/Spanish/French recognition plus translation involving English. Published WER does not establish that it beats every regional model. |
| SenseVoice and small Paraformer | Keep: SenseVoice covers five East Asian/English languages; Paraformer remains a smaller Chinese download. The previous export comparison supports the SenseVoice repin, but was not repeated on a phone in this review. |
| Dolphin Small instead of Base as a starter | Reasonable quality-first choice for supported Indic/Asian languages. An aggregate evaluation is not a guaranteed improvement for every language or accent. |
| GigaAM v3 Russian | Keep the punctuation-capable RNN-T export actually in the catalog. The previous PR description incorrectly described the final selection as CTC. |
| Multilingual Whisper rungs | Keep for broad language coverage and custom vocabulary. The 626 MB iOS large-v3-v20240930 export is Turbo despite the directory lacking `turbo`. Android uses whisper.cpp Q8; iOS uses Core ML compressed weights, so Android quantization conclusions do not apply to iOS. |
| Duplicate quantizations, older large variants, English Distil rows | Retirement simplifies choice and reclaims obsolete downloads. Distil's English-only coverage was mislabeled. Its published short-form comparison against full Large v3 is not a benchmark against the retained compressed Turbo export. |
| Android Q5 removal | Q8 has support in the pinned ARM repack implementation that Q5 lacks. This is a reason to retain Q8, not proof of a universal 2.5–2.8× phone speedup. Q5's smaller weights can matter under memory pressure; no matched phone WER/latency/peak-memory experiment was performed here. |

Primary sources: [Sherpa Moonshine exports](https://k2-fsa.github.io/sherpa/onnx/moonshine/index.html),
[NVIDIA Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3),
[NVIDIA Canary 180M](https://huggingface.co/nvidia/canary-180m-flash),
[Dolphin](https://github.com/DataoceanAI/Dolphin),
[GigaAM v3](https://huggingface.co/ai-sage/GigaAM-v3),
[Distil-Whisper](https://huggingface.co/distil-whisper/distil-large-v3), and the
vendored `android/third_party/whisper.cpp/ggml/src/ggml-cpu/arch/arm/repack.cpp`.

## Real-speech baseline

Measured 2026-10-29 with [`tools/asr-bench`](../tools/asr-bench/README.md)
(`just ios accuracy`, `just android accuracy`) on `main` at `98a7859d`. Word
error rate (WER) in percent, Open ASR Leaderboard English normaliser, on the
text the keyboard types (after repair, digits and styling). iOS models ran in
the simulator, Android whisper.cpp on the Mac through the app's JNI glue. Both
are the Mac's CPU, so no timing is reported. `file` is a finished recording;
`streamed` is a dictation decoded while recording.

| Model | Path | LibriSpeech clean | LibriSpeech other | 45–90 s long-form |
| --- | --- | --- | --- | --- |
| Parakeet 110M (iOS) | file | 3.13 | 6.28 | 4.01 |
| Parakeet 110M (iOS) | streamed | 3.20 | 5.94 | 3.56 |
| Parakeet 0.6B v2 (iOS) | file | 1.79 | 4.20 | 2.15 |
| Parakeet 0.6B v2 (iOS) | streamed | 1.79 | 3.85 | 2.08 |
| Whisper Small (iOS) | file | 3.06 | 7.73 | 3.71 |
| Whisper Small Q8 (Android) | file | 3.73 | 10.63 | — |

200 clips per short set and 24 long clips, except Whisper: 50 clips per short
set and 12 long on iOS, 100 per short set on Android. The long-form column was
measured on a set that came out entirely test-clean: the first version of
`prepare.py` drew from both corpora at once and filled up on test-clean's
chapters. It now takes half from each, so re-measure before comparing a new
long-form number with this column. FLEURS Hindi (50 clips):
Whisper Small 67.3 WER / 36.5 CER on iOS and 85.1 / 66.5 on Android.

What it showed:

- Parakeet 0.6B v2 makes about 45% fewer errors than 110M at every length.
- Streamed and whole-file decodes differ by up to half a point. The 110M int8
  model changes words with small changes in input level ("Nature" and
  "NatTure" at gains 1.5 and 3, no clipping), so this is input sensitivity,
  not a chunking defect.
- The finishing stage deleted words the model heard right: a phrase said
  twice on purpose, and "a hundred and twenty six" typed as "a hundred and 26".
- Android's cropped encoder window costs Whisper Small about a quarter more
  errors on English and most of its Hindi.
- iOS Whisper loses the end of long Hindi windows: 224 tokens run out, and
  WhisperKit 1.1.0 skips the rest of the window.
- Android Whisper Hindi text is decoded per segment, and a character split
  between segments comes out as mojibake.

## Added: Parakeet Unified 0.6B English, the English pick in place of v2

Reviewed 2026-11-03.
[nvidia/parakeet-unified-en-0.6b](https://huggingface.co/nvidia/parakeet-unified-en-0.6b)
is NVIDIA's newest English Parakeet: a FastConformer RNN-T (not TDT) trained
for offline and streaming use in one model. The catalog pins the sherpa-onnx
int8 export
(`csukuangfj2/sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming@8c3a10fb`,
663 MB), which carries only the offline half. It runs on the pinned sherpa-onnx
1.13.8 through the existing NeMo transducer path, with no runtime change.

Word error rate, Open ASR Leaderboard English normaliser, on the model's own
text and on what the keyboard types:

| Model | Set | Path | WER raw | WER finished | RTF (simulator) |
| --- | --- | --- | --- | --- | --- |
| v2 | LibriSpeech clean | file | 1.74 | 1.79 | 0.064 |
| **Unified** | LibriSpeech clean | file | **1.46** | **1.48** | 0.050 |
| v2 | LibriSpeech clean | streamed | 1.74 | 1.79 | 0.087 |
| **Unified** | LibriSpeech clean | streamed | **1.53** | **1.55** | 0.071 |
| v2 | LibriSpeech other | file | 4.11 | 4.20 | 0.119 |
| **Unified** | LibriSpeech other | file | **3.54** | **3.68** | 0.047 |
| v2 | LibriSpeech other | streamed | 3.77 | 3.85 | 0.068 |
| **Unified** | LibriSpeech other | streamed | **3.54** | **3.68** | 0.071 |
| v2 | 45–90 s long-form | file | 2.12 | 2.15 | 0.067 |
| **Unified** | 45–90 s long-form | file | **1.98** | **2.02** | 0.067 |
| v2 | 45–90 s long-form | streamed | 2.00 | 2.08 | 0.126 |
| **Unified** | 45–90 s long-form | streamed | **1.97** | **2.04** | 0.106 |

`just ios accuracy` (iOS simulator, the same 200 / 200 / 24 clips as the
baseline above). v2 is the `baseline` run; RTF is the Mac's CPU on different
days and says nothing about a phone. A paired check with the sherpa-onnx 1.13.8
Python wheel, both models decoding the same 549 test-clean and 490 test-other
utterances in alternation (greedy, four threads, whole utterances): test-clean
1.43 against 1.64, test-other 2.70 against 3.18. Unified had fewer errors on 40
test-clean clips and v2 on 21; on test-other, 60 against 31. Real-time factors
were within noise of each other (0.098 / 0.095 and 0.094 / 0.113), and peak RSS
decoding a 14 s window on macOS arm64 was 0.70 GB against v2's 0.69 GB, so the
4 GB floor stays.

The model writes its own punctuation and capitals, and in conversational speech
numbers as digits ("Revenue rose 35.3% to $1,200.", "555-0123", "6 p.m.").
LibriSpeech is read audiobook text: Unified wrote no digit in any of these clips,
and errors involving a digit after normalising were at most 0.14 points, the
same reference words as v2's. The digits do not inflate these numbers.

Two finishing defects it exposed, both shared with v2 and fixed on both
platforms:

- sherpa-onnx 1.13.8 deletes the space before every ASCII punctuation mark when
  it joins tokens, opening ones included, so "to $1,200" arrived as "to$1,200".
  The NeMo transducers now rebuild their text from the tokens and close up only
  before `, . ! ? ; : % ) ] }`. Over the 2,078 paired decodes above this changed
  two transcripts, both a space the model put before an apostrophe
  ("little 'Lisbeth"). The other two NeMo transducers were checked the same way
  on 286 Parakeet v3 decodes (English, French, German, Spanish, Italian,
  Portuguese, Dutch, Polish, Russian) and 11 GigaAM Russian ones: French
  elisions, "?", "!" and ":" came out unchanged, and the only differences were
  "$" and `<unk>` regaining their space, v3's Russian "Москва - столица" where
  sherpa-onnx typed "Москва- столица", and GigaAM's `сказал: "Бэк` where it
  typed `сказал:"Бэк`.
- A sentence ending in a dotted abbreviation got a second full stop:
  "closes at 6 p.m.." The styler now counts a masked span that ends in a stop
  as the sentence's terminator.

Not fixed: on "Johnson and Johnson" spoken by one macOS voice, Unified wrote
"Johnson ??  Johnson" — the "&" it meant comes out as two question-mark tokens
(v2 wrote `<unk>`). Seen on that synthetic sentence only.

v2 stays in the catalog, unchanged, for anyone who has it. It is out of the
English preference and accuracy ranking rather than behind Unified: it needs
exactly the memory Unified does, so it could never be the fallback, and ranking
both would spend two of the three first-run cards on 660 MB English models.

License: NVIDIA Open Model License, where v2 and v3 are CC-BY-4.0. The model card
states it is ready for commercial and non-commercial use; like every model here
it is downloaded separately and not bundled.

## Names and jargon: custom vocabulary while decoding (2026-11-03)

Measured with the `vocab-en` set of [`tools/asr-bench`](../tools/asr-bench/README.md):
50 dictation sentences dense in names and jargon, spoken by six macOS voices,
each decoded with the custom vocabulary a user would have entered (its own
terms and four others). Term accuracy is the share of term uses the finished
text spells exactly. `before` is `main` (vocabulary as Whisper's prompt and in
finishing only); `after` routes every engine's hints through
`RecognitionHints` and gives Qwen3-ASR the vocabulary as hotwords. iOS models in
the simulator, Android whisper.cpp on the Mac through the app's JNI glue.

| Model | Path | WER before | WER after | Terms before | Terms after |
| --- | --- | --- | --- | --- | --- |
| Whisper Small (iOS) | file | 2.94 | 2.94 | 97.5 | 97.5 |
| Whisper Small (iOS) | streamed | 2.94 | 2.94 | 97.5 | 97.5 |
| Whisper Small Q8 (Android) | file | 4.71 | 4.71 | 93.3 | 93.3 |
| Qwen3-ASR 0.6B (iOS) | file | 19.41 | 8.43 | 57.5 | 81.7 |
| Qwen3-ASR 0.6B (iOS) | streamed | 18.63 | 9.41 | 55.8 | 80.8 |
| Parakeet 0.6B v2 (iOS) | file | 14.71 | 14.31 | 68.3 | 69.2 |
| Parakeet 0.6B v2 (iOS) | streamed | 13.73 | 14.90 | 70.0 | 66.7 |

What it showed:

- Qwen3-ASR's hotwords are the change. Its raw term accuracy goes from 30.8%
  to 72.5%; the rest of the finished gain is `VocabularyCorrection` catching
  more near misses. One term was lost (`getUserById` written as "get user by
  ID", streamed) against 31 gained, and no clip typed one of its four unspoken
  terms.
- Whisper's prompt is unchanged in what it says, so the two runs are
  identical. The prompt-less retry of an empty decode never fired on this set.
- Parakeet v2 takes no hint, and its two runs differ only by its feature
  dither, which is drawn fresh on every decode. ±3 points of term accuracy is that
  noise; read anything smaller as nothing.
- The order of the terms matters about as much as their framing. On Android,
  writing the same terms reversed cost 1.7 to 3.3 points of term
  accuracy. A `Glossary: ` framing, which VocaMac uses, was no better than the
  bare list: in the user's order it spelled one term in 120 fewer on each
  platform (Android 92.5 vs 93.3, iOS 96.7 vs 97.5), and across both orders on
  Android the two tie exactly. The bare list stays.
- Whisper already spells most of these terms with today's prompt and
  finishing. What it misses are names whose sound and spelling part company:
  Niamh, and Nguyen spoken "Win", on both; Saoirse, Tadhg and Siddharth on
  Android too.

Synthetic speech from six voices is cleaner and more uniform than a person, so
the absolute numbers flatter every model; the differences are what carry over.

## Parakeet Unified hears custom words while it decodes (2026-11-04)

sherpa-onnx 1.13.8 can bias a NeMo transducer toward hotwords, but only in
`modified_beam_search`, with `modeling_unit = "bpe"` and a BPE vocabulary to
split each hotword into the model's word pieces. The pinned export ships the
token table and not the vocabulary, so the apps bundle one:
`assets/speech/parakeet-unified-0.6b-en.bpe.vocab`, 12,009 bytes, 1,024
pieces. `tools/model-pins/bpe_vocab.py` derives it from the SentencePiece
tokenizer inside `nvidia/parakeet-unified-en-0.6b@fe53cd88`'s `.nemo`
(fetching only that member, digest pinned) and refuses to write it unless it
rebuilds the pinned `tokens.txt` byte for byte; `check_catalogs.py` repeats
that check offline in CI. It carries the model's license, the NVIDIA Open
Model License.

Only Parakeet Unified, an RNN-T. Parakeet v2 and v3 are TDT models, whose
beam search on 1.13.8 can drop whole sentences (sherpa-onnx #3267, fixed by
#4084, which no release carries); they stay greedy until the runtime moves.

**Tuning.** The sherpa-onnx 1.13.8 Python wheel, the same C++ path, on the 50
`vocab-en` clips (120 term uses) with each clip's own vocabulary as per-stream
hotwords, the same dither noise for every configuration. Raw term accuracy;
"unspoken" counts vocabulary terms typed that the speaker never said:

| Search | Score | Terms | WER | Unspoken |
| --- | --- | --- | --- | --- |
| greedy | — | 42.5 | 20.78 | 0 |
| beam 4 | none | 43.3 | 20.78 | 0 |
| beam 2 | 2.0 / 3.0 | 66.7 / 75.8 | 13.73 / 13.73 | 0 / 0 |
| beam 4 | 1.0 / 1.5 | 66.7 / 71.7 | 13.92 / 13.14 | 0 / 0 |
| **beam 4** | **2.0** | **76.7** | **11.18** | **0** |
| beam 4 | 2.5 / 3.0 | 79.2 / 83.3 | 12.55 / 17.06 | 1 / 3 |
| beam 4 | 4.0 | 90.0 | 301.18 | 835 |
| beam 8 | 1.5 / 2.0 | 77.5 / 79.2 | 11.18 / 10.78 | 0 / 0 |
| beam 8 | 2.5 / 3.0 | 83.3 / 90.8 | 12.94 / 31.18 | 2 / 36 |

From 2.5 up the boost starts to loop ("a Jira Jira Jira Jira bug", "Siddharth
Siddharth Siddharth"), and at 4.0 it runs away. Across three dither seeds (150
decodes each) beam 4 at 2.0 spelled 77.2% with no repeated word, and beam 8 at
2.0 78.6% with three ("a new CUDA CUDA toolkit"), at about twice beam 4's
decode time on the same (loaded) Mac. Beam 4, score 2.0: the most terms before the boost
starts looping, half a step below where it does, and the cheaper beam. The
NeMo beam search runs the decoder and joiner once per hypothesis per step,
unbatched, so its cost grows with the beam.

**Two failures the boost causes, and the guard.** sherpa-onnx's NeMo beam
search adds the score to a hotword's pieces and takes it back only when a
later piece leaves the hotword. A hypothesis that has typed part of a hotword
keeps the bonus by emitting nothing more, and can outscore every hypothesis
that goes on transcribing: with all 56 terms boosted, LibriSpeech's "add a
quart of strong consom and let all continue boiling" came back as "add a
quart of strong Conflue". It also loops on a finished hotword: "tell Aoife on
Slack Slack Slack". So a window whose hotword decode leaves audible speech
after its last token (at least 1 s, starting 0.5 s after the last token
began, with a frame at least a quarter as loud as the window's loudest), or
types a hotword twice in a row, is decoded again without hotwords
(`SherpaHotwordCheck`). On the Python run of 450 clips it fired once, on a
correct one-word clip.

**Results.** `just ios accuracy` in the simulator. `unified-greedy` is the
base branch (custom words in finishing only); `unified-hotwords` this branch.
LibriSpeech clips carry no vocabulary, so both decode them greedily and the
LibriSpeech rows differ only by Parakeet's per-decode dither:

| Set | Path | WER before | WER after | Terms raw before | after | Terms finished before | after |
| --- | --- | --- | --- | --- | --- | --- | --- |
| vocab-en | file | 13.53 | **8.43** | 41.7 | **76.7** | 68.3 | **82.5** |
| vocab-en | streamed | 13.73 | **8.82** | 43.3 | **77.5** | 67.5 | **81.7** |
| LibriSpeech clean | file | 1.48 | 1.50 | | | | |
| LibriSpeech clean | streamed | 1.57 | 1.50 | | | | |
| LibriSpeech other | file | 3.66 | 3.71 | | | | |
| LibriSpeech other | streamed | 3.63 | 3.80 | | | | |

No `vocab-en` clip typed one of its unspoken terms, none lost a term greedy
spelled, and none came back empty. What it still misses are names whose sound
and spelling part company (Aoife as "AoFA", Saoirse, Tadhg, Nguyen spoken
"Win", Oluwaseun), Namrata heard as "Namita", and `getUserById`.

The cost to ordinary speech is the other half. With the whole 56-term list
boosted on every LibriSpeech clip (`background=vocab-en`, what a user with a
long list meets when dictating something unrelated to it):

| Set | Path | Greedy | All 56, no guard | All 56, with guard |
| --- | --- | --- | --- | --- |
| LibriSpeech clean | file | 1.48 | 1.62 | 1.81 |
| LibriSpeech clean | streamed | 1.57 | 1.69 | 1.72 |
| LibriSpeech other | file | 3.66 | 4.40 | 4.17 |
| LibriSpeech other | streamed | 3.63 | 4.57 | 4.31 |

The guard took back about a third of the loss on the harder set (deletions 43
to 37 and 39 to 34). What remains is a handful of clips: a hotword spelled
into ordinary speech ("Sixty Siddharth Night", "Lieutenant Cross Trees"),
and a drop it cannot see, either too close to the end of the window ("thought
Hugging", with less than a second after it) or in the middle ("strong
Continue boiling"). Clean file got worse with the guard, by one 18-second
clip losing seven words mid-window; Parakeet's dither alone moves single
clips like that. Fewer terms boost fewer chances: `vocab-en` dictations with
six or so terms showed none of this.

Decode time: the beam roughly matched greedy on the short `vocab-en` clips on
a quiet run (RTF 0.071 / 0.069 against greedy's 0.081 / 0.069, on a busier
Mac); on LibriSpeech with all 56 terms, RTF 0.064 to 0.085 against greedy's
0.049 to 0.060 on the same day. The simulator's RTF says little about a phone,
and nothing here was measured on one. A user without custom words keeps
greedy search and pays nothing.

## Added: Omnilingual ASR 300M CTC INT8

This adds a non-Whisper option for Arabic, Swahili, and the supported Indic/Asian
languages. It is an optional coverage alternative, not a claim to outperform
Dolphin or Whisper on those languages. It does not replace their starter or
high-accuracy rankings. Its 6 GB minimum is a conservative catalog policy,
not a measured peak-memory requirement.

The available November export is **365,438,543 bytes**, pinned to
`csukuangfj2/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12`
at `6fc542a3b0661c8278cca1230c34deb989f31202`. Both files have generated
SHA-256 pins. The February v2 INT8 repository resolves to
`63ee1457e8920763505e114a51ea14d31acdc6aa` but contains no runtime files;
the previous claim that the 292 MB v2 download was available was incorrect.

The native bridge uses `omnilingual.model`, greedy decoding, and existing
bounded Sherpa audio windows. It cannot force the recognition language,
translate, or accept vocabulary prompts. The picker exposes a checked subset
of 20 existing language choices; Automatic lets the model detect other supported
languages. The upstream family supports 1,600+ languages, which is not a
promise that VocaPhone offers 1,600 explicit language controls.

Validation on Apple M1 Pro: compiled VocaPhone's actual C bridge against pinned
Sherpa 1.13.8 and ONNX Runtime 1.28.2; verified the downloaded model SHA-256;
decoded the upstream English, German, Spanish, and French samples three times
each through one retained recognizer. All 12 decodes returned nonempty UTF-8;
English matched the upstream reference exactly. With two threads, 2.75–5.33 s
clips took 0.31–0.85 s. This is a bridge smoke test, not multilingual WER or
physical-phone performance validation. Audio and transcript fixtures stay out
of this repository.

Sources: [Meta model card](https://huggingface.co/facebook/omniASR-CTC-300M),
[Sherpa export and reference output](https://k2-fsa.github.io/sherpa/onnx/omnilingual-asr/models.html),
[upstream language inventory](https://github.com/facebookresearch/omnilingual-asr/blob/main/src/omnilingual_asr/models/wav2vec2_llama/lang_ids.py).

## Added: Zipformer Korean and Vietnamese

Two small icefall Zipformer transducers, as a new `zipformerTransducer` family
in both bridges (three graphs like NeMo's, but with an empty `model_type` so
sherpa-onnx reads the Zipformer metadata):

| Model | Download | Evidence | Licence |
| --- | --- | --- | --- |
| `zipformer-ko` — `k2-fsa/sherpa-onnx-zipformer-korean-2024-06-24`, all-int8 | 76 MB | KsponSpeech eval_clean CER 10.6 (greedy), upstream card | Apache-2.0 (weights) |
| `zipformer-vi` — `csukuangfj/sherpa-onnx-zipformer-vi-int8-2025-04-20` (VietASR 68M, ~70k h) | 77 MB | Level with PhoWhisper-Large (1.5B) and ahead on four of five VLSP sets, per the comparison table on `hynt/Zipformer-30M-RNNT-6000h` | Apache-2.0 |

Both were decoded with the pinned sherpa-onnx 1.13.8 (Python wheel, macOS
arm64) on their own `test_wavs`, against the exact pinned files. Two output
defects were found and fixed in the bridges rather than accepted:

- **Korean loses every word space.** sherpa-onnx's `text` joins tokens without
  the leading spaces they carry in non-Latin scripts ("지하철에서다리를벌리고…").
  The tokens themselves are right, so the family rebuilds the transcript from
  them; all four samples then match the reference transcripts.
- **Vietnamese is all capitals.** The recipe trains on upper-cased text, and the
  styler keeps 2–4 letter capitals as acronyms — most Vietnamese syllables. An
  all-capitals transcript from this family is lower-cased before styling.

`zipformer-vi` leads Vietnamese (ranking and first-run starter, above Dolphin).
`zipformer-ko` ranks after SenseVoice for Korean — no like-for-like comparison
exists — and is the smallest Korean download. No phone measurement was made.

A Q5 Large v3 Turbo for 4–5 GB Android phones was considered and left out:
the catalog is Q8-only until target-device latency, peak-memory and accuracy
evidence says otherwise (see `AGENTS.md`). Rounding reported RAM up to the
advertised size already brings 6 GB phones onto the Q8 Turbo; 4–5 GB phones
still top out at Whisper Small in the `fdroid` flavour.

## Added: Parakeet TDT-CTC 110M English (VocaHQ int8); removed: Moonshine v2

Upstream publishes Parakeet TDT-CTC 110M for sherpa-onnx only as a 458 MB FP32
graph; its int8 repository is empty. VocaHQ quantized the pinned export
(`csukuangfj/sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000@3af92f15`) with
ONNX Runtime's dynamic QUInt8 weight quantization — the method sherpa-onnx's
own NeMo export scripts use — and hosts it at
[`VocaHQ/sherpa-onnx-nemo-parakeet-tdt-ctc-110m-en-int8`](https://huggingface.co/VocaHQ/sherpa-onnx-nemo-parakeet-tdt-ctc-110m-en-int8)
with the reproduction script and CC-BY-4.0 attribution to NVIDIA.

LibriSpeech (sherpa-onnx 1.13.8, macOS arm64, greedy decoding, Open ASR
Leaderboard English normaliser, 2,620 / 2,939 utterances):

| Model | Download | test-clean | test-other | test-clean, clips < 9 s | test-other, clips < 9 s |
| --- | --- | --- | --- | --- | --- |
| Parakeet 0.6B v2 | 661 MB | 1.75 | 3.25 | 1.87 | 3.68 |
| Parakeet 110M FP32 | 458 MB | 2.93 | — | 3.24 | — |
| **Parakeet 110M int8** | **132 MB** | **3.00** | **6.20** | **3.25** | **7.02** |
| Moonshine v2 Base | 141 MB | 51.58 | 46.71 | 3.68 | 9.16 |

**Moonshine v2 (Tiny and Base) returns an empty transcript for any input of
9.4 s or more** — an ONNX Runtime broadcast failure in the merged decoder's
cross-attention, reproduced on both builds with the pinned runtime; 686 of 2,620
test-clean clips came back empty. The app hands sherpa models windows of up to
14 s, so every Moonshine dictation past ~9 s paid a failed decode and then a
blind midpoint split. The earlier latency comparison only measured 2.0–6.6 s
clips, which is why it was not seen. Even on the clips it can decode, Base is
the less accurate model. Both builds are retired onto Parakeet 110M, which is
now the English starter and the small English pick on both platforms. The
Moonshine families stay in the bridges; only the catalog rows are gone.

With Moonshine Tiny gone, the smallest iOS model that *lists* English was
Paraformer, a Mandarin model. "Smallest download" skipped a model whose
coverage of a language is only incidental, so English got Parakeet 110M.
Paraformer has since been retired; see below.

## Retired: Dolphin Small and Paraformer Small Chinese

Reviewed 2026-09-30, on both platforms (the sherpa catalogs must agree).

**Dolphin Small** was retired after reports of poor transcripts. It listed English
and the SenseVoice languages alongside its Indic and South East Asian range.
Decoded with sherpa-onnx 1.13.8 on macOS arm64, it returned nothing for English
(a synthesized sentence, the Qwen3-ASR `f1_noise` clip and a code-switched clip)
or German, answered French in Persian script and Spanish as mixed-script noise,
and dropped most of a Korean sentence. On synthesized Hindi, Thai, Indonesian,
Malay and Vietnamese it was usable. Both Dolphin ids now retire onto Whisper
Large v3 Turbo, then Whisper Small, then SenseVoice. Large v3 covers every
language Dolphin did, but Small has no Cantonese, so the migration prefers a
fitting replacement that still covers the user's languages. A 3 GB Cantonese
speaker lands on SenseVoice; English on the same phone still gets Whisper
Small. The language chosen for dictation outranks the phone and keyboard
languages, and is never traded away: a replacement that fits but lacks it is
skipped, and if nothing that fits has it (Hindi on a 2 GB phone) the selection
is cleared, unless the ladder never covered that language at all. iOS now leads with Large v3 Turbo for the old Dolphin starter
languages where it fits. Android leaves them to Whisper scoring, which keeps its
874 MB large build off first run. Vietnamese keeps `zipformer-vi`.

**Paraformer Small Chinese** only won "smallest Chinese download". SenseVoice is
the stronger Mandarin model, also covers Cantonese, and needs the same 2 GB, so
Paraformer retires onto it. With Paraformer and Dolphin gone, no catalog model
lists a language it was not built for, so the "incidental coverage" exclusion
from the smallest-download and many-languages picks is removed.

The `dolphinCtc` / `paraformer` bridge families stay, as the Moonshine ones did.

### Added as an option: Qwen3-ASR 0.6B

`csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25` runs on both pinned
runtimes (sherpa-onnx 1.13.8) as a new `qwen3Asr` / `QWEN3_ASR` bridge family:
a conv frontend, an encoder and a Qwen3 LLM decoder reading a Hugging Face
tokenizer directory (`tokenizer/vocab.json`, `merges.txt`,
`tokenizer_config.json`, all pinned) in place of `tokens.txt`. `pin_models.py`
now pins `.json` files for it. 987 MB, minimum 6 GB.

It is listed and selectable, but **not ranked first for any language** and not
a first-run default:

- Qwen's own table has the 0.6B model behind Whisper large-v3 on every
  multilingual set: Fleurs (hi, id, ms, nl, pl, th, tr, vi) 10.37 against 6.85
  WER, the 10 further Fleurs languages 21.80 against 8.16, CommonVoice 12.75
  against 10.77.
- The sherpa-onnx config has no language field. Two of five short synthesized
  Thai commands came back as invented Vietnamese.
- Upstream's default `max_new_tokens` of 128 cut a 16 s Hindi clip at about
  half. The bridges set 256; the clip then decoded in full, in 7.1 s on an M1
  Pro with two threads, inside the default 512-token context.
- About 2.2 GB peak RSS on macOS arm64.

It did well on the rest of the synthesized set: Hindi, Indonesian, Malay,
Vietnamese, Mandarin, Arabic, German, French and the noisy English clip.
Where it is offered: iOS lists it among the many-languages picks after Parakeet
v3 and Whisper Large, and Android's "Works across languages" guidance picks it
where the balanced model is a narrow specialist (SenseVoice for Japanese on an
8 GB phone). Android keeps it out of `MULTILINGUAL_PREFERENCE`, as it keeps
Whisper large off first run. Qwen3-ASR also takes the custom word list as
hotwords (see [Custom vocabulary while decoding](architecture.md#custom-vocabulary-while-decoding)
and the `vocab-en` numbers below). Needs phone latency and memory measurement
before any ranking changes.

## Replaced: MindType tagger v1.5 → v2.0 (grammar, optional, 2026-10-31)

Mindscend's v2.0 keeps v1.5's architecture, tokenizer, plausible pairs and
input and output names; the weights are a "model soup" of three fine-tunes
with phone-typing slips and more already-correct text, and `labels.json`
swaps 1,523 multi-word `APPEND_` labels the guard vetoes anyway. On our
dictation set at its recommended KEEP bias of 3 it scores precision 0.991,
recall 0.626, F0.5 0.887 and 0 false positives on correct sentences, against
v1.5's 0.944 / 0.596 / 0.846 / 0; a call costs the same. It is pinned
straight from `Mindscend/mindtype-tagger-v2.0@e58cbb68` (the `onnx/` folder)
rather than through a VocaHQ mirror. KEEP bias 4 backs an "Only sure fixes"
preference (F0.5 0.870, recall 0.585); its settings control arrives with
Writing check. Numbers and ablations:
[tools/grammar-eval](../tools/grammar-eval/README.md).

## Added: MindType tagger v1.5 (grammar, optional)

Not a speech model and not in the speech catalog: the optional "Fix grammar
(English)" stage. [MindType tagger v1.5](https://huggingface.co/Mindscend/mindtype-tagger-v1.5)
by Mindscend (Apache-2.0) is a 26.2M-parameter encoder that labels each word
`KEEP`, `DELETE`, `REPLACE_<w>`, `APPEND_<w>` or a case change, so it cannot
write a sentence nobody said. The int8 ONNX build (27 MB, 28 MB with its
tokenizer and tables) is mirrored unchanged to
`VocaHQ/mindtype-tagger-v1.5-onnx@5b6d7c30` and pinned on both platforms. The
Core ML build needs iOS 18, so iOS uses the ONNX one too.

Upstream reports F0.5 0.799 and a 2.4% false-positive rate on its own suite,
weak tense correction (F0.5 0.119), and F0.5 0.464 on real-learner CoEdIT
sentences. Upstream publishes no inference code, so the recipe was rebuilt and
checked in [tools/grammar-eval](../tools/grammar-eval/README.md) on 337
hand-written dictation-style sentences (174 already correct, 163 with the
agreement, article, homophone, `could of`, dropped-word and verb-form slips that
speech produces). Precision counts every edit, including any made to a
correct sentence:

| Configuration | Precision | Recall | F0.5 | Exact (errors) | False positives (correct) | Protected-span damage |
| --- | --- | --- | --- | --- | --- | --- |
| Shipped recipe (KEEP bias 2.0, guard) | 0.944 | 0.596 | 0.846 | 60.1% | 0.0% | 0 |
| No guard or protections | 0.903 | 0.596 | 0.819 | 59.5% | 1.7% | 0 |
| KEEP bias 0 | 0.883 | 0.620 | 0.814 | 62.6% | 1.1% | 0 |
| No `[BOS]` | 0.827 | 0.363 | 0.658 | 35.6% | 4.0% | 0 |

The set and the recipe share an author, one guard rule was fitted to the set's
only false positive (without it the rate is 0.6%), and there is no held-out
set. It fixes agreement, articles and the common homophones well, and leaves
verb forms after modals, double negatives, pronoun case and most sound-alike
content words alone. Laptop CPU latency is about 2 ms per sentence (p95 4 ms);
the real model through the iOS bridge reproduces all 44 parity cases, at a
median of 18 ms per case in a Debug simulator build, and the feature has
been checked by hand on an iPhone 14 Pro. **No phone latency measurement
has been made yet.** The stage works to a soft 150 ms budget, checked before
each sentence, each pass and each chunk: it keeps the corrections it has
finished and skips the rest, but a model call already started runs to its
end, so one call (at most 150 tokens) can carry insertion past the budget.
That overrun is logged as `grammarSlow`.

## Other candidates

Checked on Hugging Face and not added:

- **Moonshine v2 Arabic, Spanish, Japanese, Korean, Ukrainian, Vietnamese and
  Chinese.** The sherpa-onnx exports are the legacy non-streaming models, which
  Moonshine's `LICENSE` lists as the only ones *not* MIT: they remain under the
  non-commercial Moonshine Community License. Revisit if MIT streaming-derived
  exports appear.
- **Zipformer Vietnamese 30M (2026-02-09).** Smaller and better on VLSP, but
  CC-BY-NC-ND.
- **Thai Zipformer, Canary 1B v2.** No sherpa-onnx offline export found.
- Omnilingual 1B, Canary 1B, and larger generative ASR models need substantially
  more resources or additional runtime integration. A desktop leaderboard win
  alone does not justify adding them to a phone keyboard.

## Retirement migration: what the user sees

Launch moves a retired selection to its nearest surviving model but does not
download it. Until it is downloaded:

- Dictation stops **before recording** — Android with "Voice model needed" and
  a keyboard shortcut straight to the Models page, iOS with a session failure
  naming the model in plain words — instead of recording and failing at the end.
  The check is a stat of the pinned files (Android) or the verified / verifying
  sets (iOS), so a model still being hashed after launch is not a false alarm.
- The Models page shows "Your voice model was updated" with the replacement's
  plain name, what it is good at, and a one-tap download of its size.

Retired files are still deleted at launch: they cannot be loaded without their
descriptors and pins, which is the catalog history this PR removes.

Android now rounds reported RAM *up* to the advertised size (a 6 GB phone
reports ~5.5 GiB). Every `minimumRamGB` is written in advertised gigabytes, as
on iOS; flooring put every model one tier too high.

## iOS Large v3 Turbo interruption

The reported device is iPhone 14 Pro, using Large v3 Turbo with Accurate.
Inspection of pinned WhisperKit **0.18.0** confirmed two relevant behaviors:

1. Built-in VAD chunking defaults to four concurrent workers on iOS, increasing
   active decoder memory for recordings that cross the 30-second window.
2. `AudioChunking.updateSeekOffsetsForResults` logs and discards failed windows.
   A later failure can therefore return an incomplete successful transcript.
   VocaPhone previously accepted that text and deleted the original audio.

VocaPhone now owns the VAD window loop, decodes sequentially, and propagates
every window error. Existing recoverable-session handling then retains the
recording. Accurate retains its two temperature fallback attempts. Short final
windows are retained and padded past Whisper's seek cutoff. No audio is sent to
a new destination, and no transcript or audio is added to diagnostics.

Regression tests exercise bounded windows, complete sample coverage, the
short final tail, and a later-window exception that must not become success.
This establishes a real code defect. It does **not** prove that the user's
particular interruption was caused by that defect or by an iOS memory kill.

Device acceptance still needed: on iPhone 14 Pro, select the 626 MB Turbo build
and Accurate; dictate 10 s, 35 s, and 90 s passages; repeat several times from
the keyboard with the containing app in the background. Confirm the last
sentence is inserted, a failed decode remains retryable, and no jetsam event
occurs. Also exercise model retirement with installed older models and the new
Omnilingual download on physical iOS and Android devices.
