package com.vocahq.vocaphone.local

/**
 * sherpa-onnx models, pinned per file against the Hugging Face mirrors of the
 * k2-fsa release assets.
 *
 * These cover the ground whisper.cpp does not: transducer and CTC models that
 * are far faster than whisper at the same accuracy on the languages they were
 * trained for, and East Asian coverage whisper handles poorly at small sizes.
 * `SherpaFamily` decides how the files below become an `OfflineModelConfig`.
 */
internal object SherpaModelCatalog {
    val all: List<LocalModelDescriptor> = listOf(
        sherpa(
            id = "moonshine-v2-tiny-en",
            languageCodes = setOf("en"),
            displayName = "Moonshine v2 Tiny English",
            // v2 replaces v1 on every axis at once: 44 MB against 124 MB,
            // 12.01 average WER against 12.66, and faster. Measured on arm64 at
            // two threads, median of five, same audio -- v1 then v2:
            //   2.0s  23.2 -> 20.9 ms   4.0s  48.3 -> 44.1   6.6s  86.9 -> 79.2
            repository = "csukuangfj2/sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27",
            revision = "d1e6c30921780b8508d04b492dfb3ce8a51605d4",
            family = SherpaFamily.MOONSHINE_V2,
            sizeBytes = 44_243_206L,
            minimumRamGB = 2,
            languages = "English",
            englishOnly = true,
            files = listOf(
                PinnedFile("decoder_model_merged.ort", 30_412_256L,
                    "cf524c4862d36e9e5ab032eddc73637efd822d70e868ac575cf1a46e1e4708a0"),
                PinnedFile("encoder_model.ort", 13_281_600L,
                    "94e90a4654fc45cdfedb77c4c08e1739f48862998e58fada384b25118134f221"),
                PinnedFile("tokens.txt", 549_350L,
                    "2870d843e14c1e187bf1913a521562a63b53933814bd7f2145120468f494a049"),
            ),
        ),
        sherpa(
            id = "moonshine-v2-base-en",
            languageCodes = setOf("en"),
            displayName = "Moonshine v2 Base English",
            // The largest single gain in the catalog. v2 is half the size of
            // v1 (141 MB against 287 MB), 2.2 WER points better (7.84 against
            // 10.07), and faster. Measured on arm64 at two threads, median of
            // five, same audio -- v1 then v2:
            //   2.0s  43.7 -> 34.8 ms   4.0s  91.8 -> 74.4   6.6s 157.4 -> 129.7
            //
            // For context, Canary 180M scores 7.12 on the same suite but takes
            // 122/236/399 ms for those clips: three times the latency for
            // 0.7 WER points, which is the wrong trade for a keyboard.
            repository = "csukuangfj2/sherpa-onnx-moonshine-base-en-quantized-2026-02-27",
            revision = "8f4d6c58c03d40bcea40043bb7120a878f2bbef6",
            family = SherpaFamily.MOONSHINE_V2,
            sizeBytes = 141_300_566L,
            minimumRamGB = 2,
            languages = "English",
            englishOnly = true,
            files = listOf(
                PinnedFile("decoder_model_merged.ort", 109_424_400L,
                    "d9d7b333af34bc552580576ddcf248a1c6c839e0d3b43b09afb9376ed009899d"),
                PinnedFile("encoder_model.ort", 31_326_816L,
                    "7c66495948d0d08ec1af454cd4b5514862ae6511e94712a60e6d83eaec8dc8cf"),
                PinnedFile("tokens.txt", 549_350L,
                    "2870d843e14c1e187bf1913a521562a63b53933814bd7f2145120468f494a049"),
            ),
        ),
        sherpa(
            id = "parakeet-tdt-0.6b-v2-en",
            languageCodes = setOf("en"),
            displayName = "Parakeet TDT 0.6B English",
            repository = "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
            revision = "1ab9323565ddb038682214b292f588070a538ce2",
            family = SherpaFamily.NEMO_TRANSDUCER,
            sizeBytes = 661_190_513L,
            minimumRamGB = 4,
            languages = "English",
            englishOnly = true,
            files = listOf(
                PinnedFile("encoder.int8.onnx", 652_184_296L,
                    "a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab"),
                PinnedFile("decoder.int8.onnx", 7_257_753L,
                    "b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e"),
                PinnedFile("joiner.int8.onnx", 1_739_080L,
                    "7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2"),
                PinnedFile("tokens.txt", 9_384L,
                    "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d"),
            ),
        ),
        sherpa(
            id = "parakeet-tdt-0.6b-v3",
            languageCodes = PARAKEET_V3_LANGUAGES,
            detectsLanguage = true,
            displayName = "Parakeet TDT 0.6B",
            repository = "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
            revision = "2bda32ec70b097a55adaa07d9a7173915b43cc78",
            family = SherpaFamily.NEMO_TRANSDUCER,
            sizeBytes = 670_478_772L,
            minimumRamGB = 4,
            languages = "25 languages · auto-detect",
            files = listOf(
                PinnedFile("encoder.int8.onnx", 652_184_281L,
                    "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247"),
                PinnedFile("decoder.int8.onnx", 11_845_275L,
                    "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e"),
                PinnedFile("joiner.int8.onnx", 6_355_277L,
                    "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3"),
                PinnedFile("tokens.txt", 93_939L,
                    "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
            ),
        ),
        sherpa(
            id = "sense-voice",
            languageCodes = SENSE_VOICE_LANGUAGES,
            // sherpa-onnx exposes a language on the SenseVoice config, so a pick
            // here really does pin the decoder rather than only the punctuation.
            detectsLanguage = false,
            displayName = "SenseVoice Small",
            // Pinned to the 2024-07-17 export. The newer 2025-09-09 build
            // decodes badly against both runtimes this repository ships, and it
            // was the one in the catalog. Measured on macOS arm64 with the same
            // sherpa-onnx versions -- v1.12.34 (iOS) and v1.13.6 (Android) --
            // against the model's own `test_wavs`:
            //
            //   ja  2025-09-09  "家中学便当制持合五十円学校贩売交"
            //       2024-07-17  "うちの中学は弁当制で持っていけない場合は..."
            //   ko  2025-09-09  "如万性 하면서面 훨씬过呀"
            //       2024-07-17  "조금만 생각을 하면서 살면 훨씬 편할 거야"
            //   en  2025-09-09  "THE TRIVAL CHIEFTHIN CALLED FOR THE BOY..."
            //       2024-07-17  "the tribal chieftain called for the boy..."
            //   zh  2025-09-09  "开放时间早上九点至下午五点"
            //       2024-07-17  "开饭时间早上九点至下午五点"
            //
            // Japanese and Korean come back as Chinese characters, English
            // loses its casing and its words, and Chinese picks the wrong one.
            // Cantonese is identical on both, so nothing is lost by the older
            // export. Both runtimes fail the same way, so this is the export
            // and not a version range: re-measure before moving the pin.
            repository = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
            revision = "2365baeacb507f821a0c8120fcee3d484dba7a07",
            family = SherpaFamily.SENSE_VOICE,
            sizeBytes = 239_549_735L,
            minimumRamGB = 2,
            languages = "Mandarin · Cantonese · English · Japanese · Korean",
            files = listOf(
                PinnedFile("model.int8.onnx", 239_233_841L,
                    "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
                PinnedFile("tokens.txt", 315_894L,
                    "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"),
            ),
        ),
        sherpa(
            id = "dolphin-small-ctc",
            languageCodes = DOLPHIN_LANGUAGES,
            detectsLanguage = true,
            displayName = "Dolphin Small",
            repository = "csukuangfj/sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02",
            revision = "c8b6689509acfcd744c04e5e169164f9ac4cae32",
            family = SherpaFamily.DOLPHIN_CTC,
            sizeBytes = 250_163_616L,
            minimumRamGB = 3,
            languages = "40 East Asian languages",
            files = listOf(
                PinnedFile("model.int8.onnx", 249_658_954L,
                    "c1afcb9265de0ebd853eb8f570b371f399a6f9b2b9af9a3cb17c2e509171e697"),
                PinnedFile("tokens.txt", 504_662L,
                    "c3788261a51df1899ea4b210b552cd42139204de72c0ad60f6cebb199078872e"),
            ),
        ),
        sherpa(
            id = "canary-180m-flash",
            languageCodes = setOf("en", "de", "es", "fr"),
            displayName = "Canary 180M Flash",
            repository = "csukuangfj/sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8",
            revision = "9077164e0d3dd1d5353743e89ceaa1d3a770838c",
            family = SherpaFamily.CANARY,
            sizeBytes = 207_170_046L,
            minimumRamGB = 2,
            languages = "English · German · Spanish · French",
            files = listOf(
                PinnedFile("encoder.int8.onnx", 132_678_643L,
                    "7a75b4e2a5857a6dcc0819503bbe3fad66943db4a3ccf21d3f27c633667d303f"),
                PinnedFile("decoder.int8.onnx", 74_437_848L,
                    "e41a2ab9c0c2fe81a1e8ade5a45fb02a74bc4db7d1f91b89a54a25e2cf79cba2"),
                PinnedFile("tokens.txt", 53_555L,
                    "2dae6fc7815f9640645e0c765522b278ee0cef49b482d91f6913e334628d3e77"),
            ),
        ),
        sherpa(
            id = "giga-am-v3-ru",
            languageCodes = setOf("ru"),
            displayName = "GigaAM v3 Russian",
            // The RNN-T export, not the CTC one. GigaAM publishes both and its
            // own evaluation puts the transducer ahead on every set it reports
            // -- 8.4 average WER against the CTC's 9.2, and Whisper's 25.1 --
            // for 7 MB more download and no measurable latency cost (362 ms
            // against 367 ms on an 11 s clip, arm64, two threads). The
            // difference shows up as punctuation on the sample: the CTC drops
            // the comma in "может быть, украдкой" and invents one after
            // "Ничьих".
            //
            // `punct` rather than the plain export for the same reason it was
            // chosen for the CTC: a bare Russian model emits an unpunctuated
            // stream, which is the one thing dictation cannot paper over.
            //
            // The decoder and joiner are full precision while the encoder is
            // int8 -- that is how upstream ships it, and `quantizedOrPlain` in
            // the recognizers resolves each graph independently because of it.
            repository = "csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16",
            revision = "a6039be7cee829a9044a69ac0ebaf1c191217c97",
            family = SherpaFamily.NEMO_TRANSDUCER,
            sizeBytes = 231_897_202L,
            minimumRamGB = 2,
            languages = "Russian",
            files = listOf(
                PinnedFile("encoder.int8.onnx", 224_570_820L,
                    "369f35a71bf288d3b8e0391fabd8dba5f2314088d440bca474056b7b4b6e66bf"),
                PinnedFile("decoder.onnx", 4_600_132L,
                    "38fc7475443ea2a26f63211ca350f73ac50fff824ab7a3876ee2bd610c53bbc4"),
                PinnedFile("joiner.onnx", 2_712_896L,
                    "602ff7017a93311aad34df1437c8d7f49911353c13d6eae7a6ee7b041339465c"),
                PinnedFile("tokens.txt", 13_354L,
                    "39abae20e692998290c574e606f11a9edef2902a1995463fcff63d1490cf22b7"),
            ),
        ),
        sherpa(
            id = "parakeet-tdt-ctc-ja",
            languageCodes = setOf("ja"),
            displayName = "Parakeet TDT CTC Japanese",
            repository = "csukuangfj/sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8",
            revision = "bef18eb066808c90bd0f5df5be685767b0732de8",
            family = SherpaFamily.NEMO_CTC,
            sizeBytes = 655_571_161L,
            minimumRamGB = 4,
            languages = "Japanese",
            files = listOf(
                PinnedFile("model.int8.onnx", 655_542_604L,
                    "3addd00ef5bd1742078389e540b77394e4a508bdf2f4c9ad1b4a76d93e76598e"),
                PinnedFile("tokens.txt", 28_557L,
                    "732f64c53909f2620c713f4106b487d92e6f54a6915b3cd3d1dbd32f9f4f392a"),
            ),
        ),
        sherpa(
            id = "paraformer-zh-small",
            languageCodes = setOf("zh", "en"),
            displayName = "Paraformer Small Chinese",
            repository = "csukuangfj/sherpa-onnx-paraformer-zh-small-2024-03-09",
            revision = "63ddc3cd0f2810b68289a7b3876e62ef5d53d6df",
            family = SherpaFamily.PARAFORMER,
            sizeBytes = 81_904_027L,
            minimumRamGB = 2,
            languages = "Mandarin · English",
            files = listOf(
                PinnedFile("model.int8.onnx", 81_828_675L,
                    "3ef6c19369b912f7caf3cef8e545c5ccd1a33d9d7ec792a46668dc41c4b229ec"),
                PinnedFile("tokens.txt", 75_352L,
                    "4b2d964e18b9cf139b473003b6698fb2ed9a2a5ec55b93daa677b28f578897aa"),
            ),
        ),
    )

    private fun sherpa(
        id: String,
        displayName: String,
        repository: String,
        revision: String,
        family: SherpaFamily,
        sizeBytes: Long,
        minimumRamGB: Int,
        languages: String,
        files: List<PinnedFile>,
        englishOnly: Boolean = false,
        languageCodes: Set<String> = emptySet(),
        detectsLanguage: Boolean = false,
    ) = LocalModelDescriptor(
        id = id,
        displayName = displayName,
        engine = LocalModelEngine.SHERPA_ONNX,
        repository = repository,
        revision = revision,
        files = files,
        sizeBytes = sizeBytes,
        minimumRamGB = minimumRamGB,
        languages = languages,
        englishOnly = englishOnly,
        sherpaFamily = family,
        languageCodes = languageCodes,
        detectsLanguage = detectsLanguage,
    )
}
