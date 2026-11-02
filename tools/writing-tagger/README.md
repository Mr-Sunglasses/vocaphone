# Writing check's part-of-speech tagger

The agreement checks (`WritingAgreement` on both platforms) need to know which
word is a verb and which is its subject. This trains the small tagger they use
and checks that both ports agree with the reference to the tag.

```bash
python3 fetch.py                                  # UD English EWT, pinned commit, SHA-256 checked
python3 train.py ~/.cache/vocaphone/ud-english-ewt  # minutes; writes assets/keyboard/en-pos.bin
python3 fixtures.py                               # writes assets/grammar/pos_fixtures.json
python3 fixtures.py --check
```

| File | What it is |
| --- | --- |
| `postag.py` | The reference: features, 64-bit FNV-1a hashing, int16 weights, the `en-pos.bin` format. `PosTagger.kt` and `PosTagger.swift` are ports of it |
| `train.py` | A greedy averaged perceptron (Honnibal, "A good POS tagger in about 200 lines of Python") over Penn Treebank tags |
| `fetch.py` | Downloads the pinned treebank |
| `fixtures.py` | The parity fixtures both apps' tests read |

Training sees every treebank sentence three ways: as written, as people type
it (lower case, no final full stop), and with one verb put in the wrong
agreement or form ("the kids plays", "did went"), tagged as what it then is.
Without the last, the tagger calls exactly the mistakes being looked for nouns.
Words are re-split into Writing check's own tokens, so "don't" is one token
tagged `VBP+RB` and "John's" `NNP+POS`.

Training is deterministic (fixed seed and passes). On the treebank's dev set:
93.4% of tokens tagged right as written, 92.3% in lower case, 93.9% with one
verb wrong; 68 tags, 1.95 MB.

The treebank is CC BY-SA 4.0, and so is the model trained from it
(`assets/keyboard/en-pos.LICENSE`). The tools and the apps' code are not
affected.
