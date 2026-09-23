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

With Moonshine Tiny gone, the smallest iOS model that *lists* English is
Paraformer, a Mandarin model. "Smallest download" now skips a model whose
coverage of a language is only incidental, so English gets Parakeet 110M.

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
