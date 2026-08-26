# Roman Hinglish evaluation set

What this measures, how to run it, and — the part that matters most — where the
reference transcripts come from.

Nothing here runs on a phone or ships in either app. It is a desktop harness for
deciding whether the Roman Hinglish model is good enough to stop being
experimental.

## The reference problem, stated plainly

Word error rate needs a reference transcript. For this mode the reference has to
be **Roman Hinglish**, and no public speech corpus publishes one. Common Voice
Hindi and FLEURS publish Devanagari; CMU Hinglish DoG publishes real
Roman-Hinglish text but no matching audio. Romanizing a Devanagari reference with
this repo's own transliterator and then scoring against it would measure the
transliterator, not the model.

So the manifest has two tiers, and each is honest about what it can support.

| Tier | What it is | Reference | Good for |
| --- | --- | --- | --- |
| `samples` | 11 public clips from the Apex model repository (Apache-2.0), five of them Common Voice Hindi (CC0) | Six carry the text the model card publishes (`model-card`); five carry none (`unlabelled`) | Devanagari leakage, translation rate, RTF, time to first transcript, peak RSS — none of which need a trustworthy reference |
| `prompts` | 40 sentences read aloud by whoever is running the benchmark | The sentence that was read, so it is exact by construction (`read-aloud`) | Everything, including WER, CER and English preservation |

`model-card` references are the model's own published output. `score.py`
therefore **excludes them from WER and CER by default** — scoring a model against
its own output is not a measurement. Pass `--trust-model-card` to include them
anyway when comparing a *different* model against Apex.

## Categories

The 40 prompts cover every category worth separating, because the failure modes
differ and an average hides them:

`conversational` · `technical` · `proper-nouns` · `numbers` · `hindi-heavy` ·
`english-heavy` · `disfluent` · `questions` · `protected`

`protected` is dictation-specific: paths, email addresses and commands spoken
aloud, which is where a normalization layer does the most damage if it is wrong.

What the prompts deliberately do **not** cover, and what a full evaluation still
needs:

- **Accent breadth.** One reader is one accent. Record the prompts again with a
  second and third speaker and score each set separately.
- **Noise.** Record one pass in a quiet room and one in a noisy one. `score.py`
  takes `--audio-dir`, so each pass is its own directory and its own row.
- **Fast speech and long pauses.** The `disfluent` prompts approximate this;
  reading them at speed is the actual test.

## Running it

```bash
# One-time: build whisper.cpp and get the model.
cmake -S android/third_party/whisper.cpp -B /tmp/whisper-build -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/whisper-build -j

# The public clips. Needs ffmpeg. Writes into ./audio, which is gitignored.
python3 tools/hinglish/benchmark/fetch.py

# The read-aloud prompts. Reads each sentence out, records, writes ./audio.
python3 tools/hinglish/benchmark/record.py

# Score.
python3 tools/hinglish/benchmark/score.py \
  --whisper-cli /tmp/whisper-build/bin/whisper-cli \
  --model ~/models/ggml-apex-hinglish-q5_0.bin \
  --normalize \
  --json /tmp/apex.json
```

`--normalize` applies a Python port of the app's normalization layer, so the
numbers describe what a user would actually see rather than the raw decode. Run
it both ways: the difference between them is exactly what the normalizer is
worth.

To compare against the stock multilingual model on the same audio — which is the
comparison that decides whether this mode earns its download:

```bash
python3 tools/hinglish/benchmark/score.py \
  --whisper-cli /tmp/whisper-build/bin/whisper-cli \
  --model ~/models/ggml-large-v3-turbo-q5_0.bin \
  --json /tmp/turbo.json
```

## Metrics

| Metric | What a bad number means |
| --- | --- |
| `wer` / `cer` | Words came back wrong. Computed on collapsed spellings, so "mujhe" and "muje" are not counted as an error — see `collapse` in `score.py` |
| `english_preservation` | Words genuinely spoken in English did not come back as English. A Hindi-only model fails this by romanizing them; a translation fails it in the other direction |
| `devanagari_leakage` | The mode broke its one promise. Must be 0 after `--normalize` |
| `translation_rate` | The model answered the meaning instead of the words |
| `rtf` | Decode seconds per audio second on this machine |
| `ttft_ms` | What a dictation user waits for. Whisper does not stream, so on a short clip this is the whole decode |
| `peak_rss_mb` | Peak resident memory of the decode process |

Phone-side CPU, GPU and battery cost are **not** measured here and this harness
cannot measure them: it runs on a desktop. Take those from a device session as
described in `docs/device-setup.md`.

## Adding a sample

1. Add an entry to `samples` with `url`, `file`, `license`, `attribution`,
   `category`, `reference` and `english_words`.
2. `python3 fetch.py --record-digests` once, to pin the source SHA-256.
3. Commit the manifest. **Never commit the audio** — see AGENTS.md.

Only add audio whose licence allows redistribution of the *link* and whose
speaker consented. No private recordings, no clips scraped from anywhere.
