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
     * MindType tagger v2.0 by Mindscend (Apache-2.0): an encoder-only edit
     * tagger, one label per word, so it cannot write a sentence nobody said.
     * Pinned straight from Mindscend's repository at an immutable revision,
     * per file by size and SHA-256; the files sit in its `onnx/` folder and
     * keep that layout on disk (see [modelFolder]). The recipe that runs it is
     * `tools/grammar-eval/infer.py`.
     */
    val tagger = GrammarModelDescriptor(
        id = "mindtype-tagger-v2.0",
        displayName = "Grammar model",
        repository = "Mindscend/mindtype-tagger-v2.0",
        revision = "e58cbb68c382a894a9f6de704fe385ec260f0949",
        sizeBytes = 28_115_617L,
        files = listOf(
            PinnedFile("onnx/config.json", 149L,
                "dde7552bfb73798ead6fbc9e14bb5b4aee062bf168b21341e69a16152a571241"),
            PinnedFile("onnx/labels.json", 297_669L,
                "1a8f56abf4ecf5adebf726c561c36c6f634309e2fca1857658df0ed22e504abd"),
            PinnedFile("onnx/mindtype_tagger.onnx", 26_700_289L,
                "cde26b40d62216c0b5680725b5e3f3b438f50cb6d02e05c395bf13059467da76"),
            PinnedFile("onnx/plausible_pairs.json", 4_450L,
                "201a30cd6fcc129070c0637b4566820c7cb4d77ef3969a7575af591a17e281f4"),
            PinnedFile("onnx/tokenizer.json", 1_113_060L,
                "7430be0917758ae85b0322ed2686b9e14e7cb322e2cafa5f87f526544ccd829b"),
        ),
    )

    /**
     * Grammar models an earlier build downloaded. Their folders are removed
     * on the next start, and someone who had a grammar setting on gets
     * [tagger] downloaded in their place rather than a switch that silently
     * does nothing.
     */
    val retiredIds = listOf("mindtype-tagger-v1.5")

    /** The folder, relative to the model's directory, that holds its files. */
    fun modelFolder(model: GrammarModelDescriptor): String =
        model.files.first().path.substringBeforeLast('/', missingDelimiterValue = "")

    /**
     * The tagger runs on the ONNX Runtime that ships beside sherpa-onnx, so it
     * is exactly as available as sherpa: absent from `fdroid`, and only on the
     * two Arm ABIs.
     */
    val available: Boolean get() = LocalModelCatalog.sherpaAvailable

    fun downloadUrl(model: GrammarModelDescriptor, file: PinnedFile): String =
        "https://huggingface.co/${model.repository}/resolve/${model.revision}/${file.path}"
}
