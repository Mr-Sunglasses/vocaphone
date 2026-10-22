package com.vocahq.vocaphone.local

/**
 * The on-device grammar model for "Fix grammar (English)".
 *
 * Deliberately not a [LocalModelDescriptor] and not in [LocalModelCatalog.all]:
 * it transcribes nothing, so it must stay out of the model picker, the
 * recommendations, the speech download slot and every sweep over speech
 * models. It is pinned the same way, per file by size and SHA-256, and
 * `tools/model-pins/check_catalogs.py` checks it against iOS's
 * `grammar_model_pins.json`.
 */
data class GrammarModelDescriptor(
    val id: String,
    val displayName: String,
    val repository: String,
    val revision: String,
    val files: List<PinnedFile>,
    val sizeBytes: Long,
)

internal object GrammarModelCatalog {
    /**
     * MindType tagger v1.5 by Mindscend (Apache-2.0): an encoder-only edit
     * tagger, one label per word, so it cannot write a sentence nobody said.
     * VocaHQ's repository is a byte-identical mirror of the upstream `onnx/`
     * folder at `a737fbc7f563104d3d07cfeb198077950e223101`. The recipe that
     * runs it is `tools/grammar-eval/infer.py`.
     */
    val tagger = GrammarModelDescriptor(
        id = "mindtype-tagger-v1.5",
        displayName = "Grammar model",
        repository = "VocaHQ/mindtype-tagger-v1.5-onnx",
        revision = "5b6d7c3004677870122c10d84f78b35dcb760ff8",
        sizeBytes = 28_114_718L,
        files = listOf(
            PinnedFile("mindtype_tagger.onnx", 26_700_289L,
                "f082574ef27d3d0e2929ef321ab7490c08002fc6475ea7d9edbe7e534777319b"),
            PinnedFile("tokenizer.json", 1_113_060L,
                "7430be0917758ae85b0322ed2686b9e14e7cb322e2cafa5f87f526544ccd829b"),
            PinnedFile("labels.json", 296_770L,
                "62df98ed27d01c107c77690c73ec346c2a4a4e37cc850de5381a833589760891"),
            PinnedFile("plausible_pairs.json", 4_450L,
                "201a30cd6fcc129070c0637b4566820c7cb4d77ef3969a7575af591a17e281f4"),
            PinnedFile("config.json", 149L,
                "dde7552bfb73798ead6fbc9e14bb5b4aee062bf168b21341e69a16152a571241"),
        ),
    )

    /**
     * The tagger runs on the ONNX Runtime that ships beside sherpa-onnx, so it
     * is exactly as available as sherpa: absent from `fdroid`, and only on the
     * two Arm ABIs.
     */
    val available: Boolean get() = LocalModelCatalog.sherpaAvailable

    fun downloadUrl(model: GrammarModelDescriptor, file: PinnedFile): String =
        "https://huggingface.co/${model.repository}/resolve/${model.revision}/${file.path}"
}
