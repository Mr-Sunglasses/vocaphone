# Roman Hinglish

**Experimental.** Android only. Off unless you go looking for it.

Speak the way a lot of people in India actually speak — Hindi and English in the
same sentence — and get it back in one Latin alphabet:

> "आज मुझे office में एक important meeting attend करनी है"
> → **"Aaj mujhe office mein ek important meeting attend karni hai."**

Two things it is deliberately not:

- Not Devanagari. "आज मुझे office में…" is a failure of this mode, not a variant
  of it. Pick **Hindi** with a multilingual model for that.
- Not a translation. "I have to attend an important meeting today" is a failure
  too. This mode transcribes the words that were said, not their meaning.

## Turning it on

1. **Settings → On-device model → More models**
2. Download **Hinglish — Roman (Experimental)** — 574 MB, needs 4 GB of RAM.
3. **Settings → Transcription language → Hinglish — Roman**

The language row is greyed out until that model is downloaded and selected, and
it is the only model that offers it. Every other model — on the phone or on your
gateway — leaves the row disabled with "Needs a different model", because asking
any of them for Roman Hinglish gets Devanagari or an English translation rather
than an error.

Selecting a different model afterwards falls the setting back to **Automatic**
rather than sending a language nothing can honour.

## The model

| | |
| --- | --- |
| Upstream | [`Oriserve/Whisper-Hindi2Hinglish-Apex`](https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Apex) |
| Licence | Apache-2.0 |
| Base | `openai/whisper-large-v3-turbo`, fine-tuned on romanized Hindi |
| Architecture | 32 encoder layers, 4 decoder layers, `d_model` 1280, 128 mel bins, 51866 tokens — turbo's topology exactly, which is why whisper.cpp runs it unmodified |
| Download | 574 MB (`q5_0`), one file |
| Requirement | 4 GB RAM, Android only |
| Upstream WER | Common Voice 35.96 · FLEURS 29.79 · IndicVoices 47.64, per the model card |

Attribution, as Apache-2.0 asks: the weights are Oriserve's work, redistributed
here only as a pinned download link. VocaPhone modifies nothing about them.

### Why the weights are pinned where they are

Oriserve publishes safetensors and nothing else — no GGML, which is the only
format whisper.cpp reads. The catalog therefore pins a **third-party GGML
conversion**, at an immutable commit, by SHA-256:

```
repository  Marquestra/Whisper-Hindi2Hinglish-Apex-GGML
revision    d1de3ff618856e5675c47d3158ca820506fb4d9e
file        ggml-apex-hinglish-q5_0.bin
sha256      9d877151b15cec1feb9110cfbc0a3162cf377bcc0ab1935174226f461cf60f13
```

That digest was not taken on trust. `tools/hinglish/convert-apex-ggml.sh`
converts Oriserve's own weights from scratch — pinned model revision, pinned
whisper.cpp revision — and the `fp16` file it produces is **byte-for-byte
identical** to the one in that repository (`84457be0…`), which is what
establishes that the conversion is of these weights and nothing else. Re-run it
before moving the pin, ever.

The download is verified again on the phone: `LocalModelManager` hashes the
bytes as they arrive, discards the file if the digest does not match, and
`LocalModelIntegrity` re-checks size and its verification marker before every
load.

### Replacing or updating the model

1. Convert and take digests: `./tools/hinglish/convert-apex-ggml.sh`
2. Confirm the digest against whatever repository you intend to pin.
3. Update `id`, `repository`, `revision`, `files` and `sizeBytes` in
   `LocalModelCatalog.hinglish` (Kotlin).
4. `just android test '*HinglishModelTest'` — the pin's shape is asserted there.
5. Benchmark before and after: `tools/hinglish/benchmark/README.md`. A pin move
   that has not been benchmarked is a regression waiting to happen.

## Privacy

Identical to every other on-device model. The audio never leaves the phone: the
model is downloaded once from Hugging Face and every decode after that is local,
offline-capable, and involves no server of ours or anyone else's. The
normalization layer below is a lookup table and a transliterator — no cloud LLM,
no network, nothing to opt out of.

## The spelling convention

Roman Hinglish has no orthography, so this repository picked one and wrote it
down. Two layers produce it:

1. The **model** writes Latin directly; its spelling is its own.
2. **`HinglishNormalizer`** cleans up after it — transliterating any Devanagari
   that leaks through, and settling a short list of words on one spelling.

Both layers are on-device, deterministic, and unit-tested
(`HinglishNormalizerTest`, `DevanagariRomanizerTest`).

### Transliteration rules

Applied by `DevanagariRomanizer` when Devanagari reaches the output. It is not
IAST: the goal is what people type, not what a linguist would write.

| Rule | Example |
| --- | --- |
| The implicit `a` is dropped at the end of a word | घर → `ghar`, not `ghara` |
| …and mid-word before a written vowel | करना → `karna`, not `karana` |
| …but never on the first syllable | पता → `pata`, not `pta` |
| …and not where the next syllable has no written vowel either | समझ → `samajh` |
| Long vowels shorten word-finally | आज → `aaj`, करना → `karna`; ठीक → `theek`, कभी → `kabhi` |
| A trailing nasal does not count as the end | नहीं → `nahin`, not `naheen` |
| Anusvara is `m` before a lip consonant, `n` elsewhere | संभव → `sambhav`, अंदर → `andar` |
| Nukta letters take their own sounds | ज़ → `z`, फ़ → `f`, ड़ → `r` |
| Danda becomes a full stop; Devanagari digits become Latin | ठीक। → `theek.`, १२३ → `123` |

Devanagari is always **transliterated, never deleted**. Dropping it would lose
words the user said while leaving a transcript that still looks clean.

### Settled spellings

Applied only to words the transliterator produced, because provenance matters:
`men` out of the transliterator is में; `men` that arrived in Latin is the
English plural and is left alone.

| | |
| --- | --- |
| `mein` | में — mechanically "men", but nobody writes that |
| `kyun`, `kyunki` | not `kyon` |
| `hoon` | not `hun` |

Applied to the whole transcript, including what the model wrote in Latin. Every
entry is a form that is **not** an English word, which is what makes it safe:

`muje`/`mujey`/`mujhy` → `mujhe` · `kyu`/`kyoon` → `kyun` · `nahi`/`nhi` →
`nahin` · `thik`/`thk` → `theek` · `acha`/`achha` → `accha` ·
`bahot`/`bhot` → `bahut` · `kese` → `kaise` · `krna` → `karna` ·
`krke` → `karke` · `smjh` → `samajh`

And one guarded rule: **`hey` → `hai`**, but only lowercase and mid-sentence.
"theek hey" is Hindi; "Hey, kaise ho?" is English and stays. Wrong in the safe
direction leaves a spelling slightly off; wrong in the other direction rewrites
what someone said.

### What is never touched

URLs, email addresses, file paths, commands, filenames, `@handles`, `#hashtags`
and shouted abbreviations (`API`, `GPU`) are masked before any rule runs and
restored verbatim afterwards. Capitalization and sentence terminators are not
this layer's job — `TranscriptStyler` runs after it and owns them for every
language, exactly as it does for Hindi or German.

Every pass is individually switchable through `HinglishNormalizer.Options`, for
a build that wants transliteration without the spelling opinions.

## Measured, so far

One run of `tools/hinglish/benchmark/` over the 11 public clips, on an Apple
Silicon Mac, `q5_0` in both cases. Both models are the same size and the same
architecture, so this is close to a controlled comparison of the fine-tune
alone.

| | stock `large-v3-turbo` | + the normalization layer | **Hinglish Apex** |
| --- | --- | --- | --- |
| Devanagari leakage | **100%** | 0% | **0%** |
| Translation rate | — | — | 0% |
| Real-time factor | 0.34 | 0.34 | 0.30 |
| Time to first transcript | 1.53 s | 1.51 s | 1.35 s |
| Peak RSS | 846 MB | 847 MB | 835 MB |
| Download | 574 MB | 574 MB | 574 MB |

The first column is why the mode exists: asked for Hindi, the stock model
returns Devanagari every single time, which is a different feature.

The second column is the more interesting one, because it is the cheap
alternative — keep the model you already have and just transliterate. It fixes
the script and nothing else, and the English is where it falls down:

| | stock turbo + transliteration | Hinglish Apex |
| --- | --- | --- |
| | `…gul par parpormens pul` | `…gul par performance full` |
| | `apanra logan` | `Aap pandrah log hain.` |
| | `yenjar saaink rikhenge` | `Main just thank you, thank you.` |

A transliterator cannot recover an English word the decoder already wrote in
Devanagari — "performance" comes back as "parpormens" — and on conversational
audio the stock model's Hindi is poor enough that romanizing it faithfully just
produces readable nonsense. The fine-tune is doing the work.

Indicative accuracy, over the six clips whose reference the model card
publishes: **WER 0.23, CER 0.14, English preservation 1.00, translation rate 0.**
Treat that as a smoke test rather than a result — the references are Apex's own
published output, which is why `score.py` excludes them unless you pass
`--trust-model-card`. A real word error rate needs the read-aloud set recorded;
see the benchmark README.

## Known limitations

- **Android only.** iOS runs WhisperKit, which needs a Core ML build; no verified
  one exists for Apex. The language row, the gating and the whole normalization
  layer are mirrored in Swift and tested there, so adding the model later is one
  catalog entry rather than a port — but until then the row is unreachable on
  iOS and a test asserts that it is.
- **No translation.** The row is unavailable for this model on purpose. Whisper's
  translate task would still run and would hand back the English translation this
  mode exists to avoid.
- **One output, always.** There is no way to ask this model for Devanagari or for
  any other language. It answers everything in Roman Hinglish, which is why it
  claims one language code and not `hi`.
- **574 MB and 4 GB of RAM.** A large-class encoder. On a mid-range phone expect
  it to be slower than the small multilingual models, and it will not stream —
  whisper never does here.
- **Word error rate is not properly measured yet.** The numbers above come from
  11 short public clips, six of which are scored against the model's own
  published output. The 40-prompt read-aloud set exists in the manifest and has
  not been recorded, so nothing here covers accent breadth, noise, or fast
  speech. Until it has, "experimental" is the accurate label and the reason the
  mode is kept out of every recommendation.
- **Not a corrector.** It will not fix grammar, and it will not rescue a word it
  heard wrong. Deliberately: over-correction on a dictation transcript is worse
  than an odd spelling, because the user cannot tell it happened.
