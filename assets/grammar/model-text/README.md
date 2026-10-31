# Grammar model text files, for tests

`tokenizer.json`, `labels.json` and `plausible_pairs.json` from the `onnx/`
folder of [MindType tagger v2.0](https://huggingface.co/Mindscend/mindtype-tagger-v2.0)
by Mindscend, revision `e58cbb68c382a894a9f6de704fe385ec260f0949`, unchanged.
Licensed under the Apache License 2.0
(<https://www.apache.org/licenses/LICENSE-2.0>).

Neither app ships these: the app downloads them with the model and checks them
against the pins in `GrammarModelCatalog.kt` and `grammar_model_pins.json`.
They are here so the Kotlin and Swift unit tests can check their tokenizer and
guard against `../parity_fixtures.json` without a network, and those tests
assert that these copies still match the pins.
