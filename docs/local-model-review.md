# Local model review

Reviewed for PR #229 on 2026-09-19. Catalog size is a product trade-off, not an
accuracy leaderboard: published WER, an export's correctness, phone latency,
working memory, language coverage, and download size are separate evidence.

## Retained and retired models

| Choice | Assessment |
| --- | --- |
| Moonshine v2 Tiny and Base English | Keep both: different download budgets, with the two-graph export supported by the pinned Sherpa runtime. The PR's earlier arm64 timing measurements are desktop evidence, not iPhone or Android measurements. |
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

## Other candidates

- Moonshine v2 Arabic, Spanish, Japanese, Korean, Ukrainian, Vietnamese, and
  Chinese exports already fit the new merged-decoder bridge. They are useful
  candidates for smaller language-specific downloads; add them after checking
  the exact quantized export against current specialists on representative
  speech, including accents and background noise.
- Omnilingual 1B, Canary 1B, and larger generative ASR models need substantially
  more resources or additional runtime integration. A desktop leaderboard win
  alone does not justify adding them to a phone keyboard.
- The smaller Parakeet 110M and multilingual Fast Conformer exports remain
  candidates if complete compact INT8 artifacts become available. Do not
  substitute their much larger FP32 downloads under an INT8 size claim.

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
