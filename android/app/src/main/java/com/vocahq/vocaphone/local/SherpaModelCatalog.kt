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
            id = "moonshine-tiny-en",
            languageCodes = setOf("en"),
            displayName = "Moonshine Tiny English",
            repository = "csukuangfj/sherpa-onnx-moonshine-tiny-en-int8",
            revision = "bf2b762c076d8ea61e2af0b3851c9564fb77552e",
            family = SherpaFamily.MOONSHINE,
            sizeBytes = 123_967_539L,
            minimumRamGB = 2,
            languages = "English",
            englishOnly = true,
            files = listOf(
                PinnedFile("preprocess.onnx", 6_800_738L,
                    "f33addce61a143460fe753b5ee5b7db255e5140b5b779c065b94f6c83ff0bf4e"),
                PinnedFile("encode.int8.onnx", 18_249_187L,
                    "8774dfba578de027ec6595c2c654a0836434489bc963a0db124a7f181f571acb"),
                PinnedFile("uncached_decode.int8.onnx", 53_216_096L,
                    "216737000dd5881a17aa043f6bbd286add33e4c3b0ae257153e2ec15438bdc41"),
                PinnedFile("cached_decode.int8.onnx", 45_264_830L,
                    "2aff28bba6a03d8dcf5c9feac45462629bae37317442299f28115ad09da773f6"),
                PinnedFile("tokens.txt", 436_688L,
                    "1165c2aeb9f72f457a83be2d459a09054f27490acd9b41bd43794dfd25e296ea"),
            ),
        ),
        sherpa(
            id = "moonshine-base-en",
            languageCodes = setOf("en"),
            displayName = "Moonshine Base English",
            // Kept for latency, not for average WER, and the two disagree here.
            // Canary 180M is smaller and scores better on the Open ASR English
            // suite (7.12 against 10.07), which is an argument for dropping this
            // row until you measure the thing a dictation keyboard is actually
            // waiting on. On arm64 at two threads, decoding the same audio:
            //
            //             Moonshine Base   Canary 180M
            //   2.0s          48 ms          122 ms
            //   4.0s         101 ms          236 ms
            //   6.6s         170 ms          399 ms
            //
            // 2.4-2.5x, at every length people actually dictate at. Moonshine
            // encodes variable-length audio rather than padding to a fixed
            // window, which is the whole point of the architecture and does not
            // show up in a WER table computed over meeting and earnings-call
            // recordings. `scoreModel` already ranks this family above every
            // other for the same reason.
            repository = "csukuangfj/sherpa-onnx-moonshine-base-en-int8",
            revision = "052b0798ad1bf046a140fdd4efcd9426530fa3f5",
            family = SherpaFamily.MOONSHINE,
            sizeBytes = 286_929_760L,
            minimumRamGB = 3,
            languages = "English",
            englishOnly = true,
            files = listOf(
                PinnedFile("preprocess.onnx", 14_077_290L,
                    "ffa630d395c5ccf76f5d4954be5b882df76aaf6491519ec01fd82ea7a3819fb2"),
                PinnedFile("encode.int8.onnx", 50_311_494L,
                    "7e38770f776f2e5583a53b052936005df2ba5c833d7e09c2a5fd796b94bf73e2"),
                PinnedFile("uncached_decode.int8.onnx", 122_120_451L,
                    "c01f4b35093bcac20d352d23a75a539e772964579f9d024a90e5e6f09cae9987"),
                PinnedFile("cached_decode.int8.onnx", 99_983_837L,
                    "2db74e51cedf64a8b1be3c8192e0bb5e4923af0e90bd9e87f8e8771873f8ea03"),
                PinnedFile("tokens.txt", 436_688L,
                    "1165c2aeb9f72f457a83be2d459a09054f27490acd9b41bd43794dfd25e296ea"),
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
            id = "giga-am-ctc-v3-ru",
            languageCodes = setOf("ru"),
            displayName = "GigaAM CTC Russian",
            // v3 rather than v2, and the `punct` export rather than the plain
            // one: a bare CTC model emits an unpunctuated stream, which is the
            // one thing dictation cannot paper over. The token table grows from
            // 196 bytes to 2 KB because of it.
            repository = "csukuangfj/sherpa-onnx-nemo-ctc-punct-giga-am-v3-russian-2025-12-16",
            revision = "4fb5407ff028a69fec516cdf4c10fac9ddea7c16",
            family = SherpaFamily.NEMO_CTC,
            sizeBytes = 224_895_668L,
            minimumRamGB = 2,
            languages = "Russian",
            files = listOf(
                PinnedFile("model.int8.onnx", 224_893_661L,
                    "d5fea8df94263c285e54b21e5774b707c707192d3bdbeffd7b1eb07fb6743b35"),
                PinnedFile("tokens.txt", 2_007L,
                    "142de7570b3de5b3035ce111a89c228e80e6085273731d944093ddf24fa539cd"),
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
