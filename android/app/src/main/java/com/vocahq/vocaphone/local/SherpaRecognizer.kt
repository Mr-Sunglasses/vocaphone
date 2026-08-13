package com.vocahq.vocaphone.local

import com.k2fsa.sherpa.onnx.OfflineCanaryModelConfig
import com.k2fsa.sherpa.onnx.OfflineDolphinModelConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineMoonshineModelConfig
import com.k2fsa.sherpa.onnx.OfflineNemoEncDecCtcModelConfig
import com.k2fsa.sherpa.onnx.OfflineParaformerModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import com.vocahq.vocaphone.core.TranscriptionQuality
import java.io.File

/**
 * One sherpa-onnx recognizer.
 *
 * Every family in [SherpaFamily] differs only in which pinned files go into
 * which slot of `OfflineModelConfig`, so adding a family is a `when` branch here
 * plus an entry in [SherpaModelCatalog].
 */
internal class SherpaRecognizer private constructor(
    private val recognizer: OfflineRecognizer,
) {
    fun transcribe(samples: FloatArray): SherpaTranscript {
        var transcript = SherpaTranscript.EMPTY
        SherpaLongAudio.chunks(samples).forEach { chunk ->
            val chunkResult = transcribeChunk(samples.copyOfRange(chunk.start, chunk.endExclusive))
            transcript = transcript.append(chunkResult, deduplicateOverlap = chunk.overlapsPrevious)
        }
        return transcript.copy(text = transcript.text.trim())
    }

    /** One already-bounded chunk used by the during-recording pipeline. */
    fun transcribeChunk(samples: FloatArray): SherpaTranscript = SherpaEmptyChunkRecovery.decode(
        samples = samples,
        decodeOnce = ::decode,
    )

    private fun decode(samples: FloatArray): SherpaTranscript {
        val stream = recognizer.createStream()
        return try {
            stream.acceptWaveform(samples, SherpaLongAudio.SAMPLE_RATE)
            recognizer.decode(stream)
            val result = recognizer.getResult(stream)
            SherpaTranscript(
                text = result.text.trim(),
                language = SherpaTranscript.languageCode(result.lang),
            )
        } finally {
            stream.release()
        }
    }

    fun release() = recognizer.release()

    companion object {
        /**
         * @param language a two-letter code, or "auto" to let the model decide.
         *   Only the families that accept a language hint use it.
         */
        fun create(
            model: LocalModelDescriptor,
            directory: File,
            language: String,
            threads: Int,
            quality: TranscriptionQuality,
        ): SherpaRecognizer {
            val family = requireNotNull(model.sherpaFamily) {
                "${model.displayName} has no sherpa-onnx family"
            }
            fun path(name: String): String {
                val file = File(directory, name)
                require(file.isFile) { "${model.displayName} is missing $name" }
                return file.absolutePath
            }

            val tokens = path("tokens.txt")
            val modelConfig = when (family) {
                SherpaFamily.NEMO_TRANSDUCER -> OfflineModelConfig(
                    transducer = OfflineTransducerModelConfig(
                        encoder = path("encoder.int8.onnx"),
                        decoder = path("decoder.int8.onnx"),
                        joiner = path("joiner.int8.onnx"),
                    ),
                )

                SherpaFamily.SENSE_VOICE -> OfflineModelConfig(
                    senseVoice = OfflineSenseVoiceModelConfig(
                        model = path("model.int8.onnx"),
                        language = if (language == "auto") "" else language,
                        useInverseTextNormalization = true,
                    ),
                )

                SherpaFamily.MOONSHINE -> OfflineModelConfig(
                    moonshine = OfflineMoonshineModelConfig(
                        preprocessor = path("preprocess.onnx"),
                        encoder = path("encode.int8.onnx"),
                        uncachedDecoder = path("uncached_decode.int8.onnx"),
                        cachedDecoder = path("cached_decode.int8.onnx"),
                    ),
                )

                SherpaFamily.DOLPHIN_CTC -> OfflineModelConfig(
                    dolphin = OfflineDolphinModelConfig(model = path("model.int8.onnx")),
                )

                SherpaFamily.CANARY -> OfflineModelConfig(
                    canary = OfflineCanaryModelConfig(
                        encoder = path("encoder.int8.onnx"),
                        decoder = path("decoder.int8.onnx"),
                        srcLang = if (language == "auto") "en" else language,
                        tgtLang = if (language == "auto") "en" else language,
                        usePnc = true,
                    ),
                )

                // Upstream is inconsistent about whether the single CTC graph is
                // quantized, so whichever one the catalog pinned is the one here.
                SherpaFamily.NEMO_CTC -> OfflineModelConfig(
                    nemo = OfflineNemoEncDecCtcModelConfig(
                        model = path(model.primaryFile.path),
                    ),
                )

                SherpaFamily.PARAFORMER -> OfflineModelConfig(
                    paraformer = OfflineParaformerModelConfig(model = path("model.int8.onnx")),
                )
            }.copy(
                tokens = tokens,
                numThreads = threads,
                provider = "cpu",
                modelType = family.sherpaModelType,
            )

            // Never `quality.sherpaDecodingMethod` on its own: a family that
            // does not support beam search answers it by killing the process.
            val decodingMethod = family.decodingMethod(quality)
            return SherpaRecognizer(
                OfflineRecognizer(
                    assetManager = null,
                    config = OfflineRecognizerConfig(
                        modelConfig = modelConfig,
                        decodingMethod = decodingMethod,
                        maxActivePaths = quality.sherpaMaxActivePaths,
                    ),
                ),
            )
        }
    }
}

/**
 * A decoded chunk, and the language the model said it was.
 *
 * Only SenseVoice fills the language in — it decodes a `<|en|>`-style tag as its
 * first token. The other families leave it empty, and the writing styles then
 * fall back to inspecting the text, exactly as they always have.
 */
internal data class SherpaTranscript(val text: String, val language: String = "") {

    /** The first language anything reported wins; later chunks rarely disagree. */
    fun append(next: SherpaTranscript, deduplicateOverlap: Boolean): SherpaTranscript =
        SherpaTranscript(
            text = SherpaTranscriptMerger.append(text, next.text, deduplicateOverlap),
            language = language.ifEmpty { next.language },
        )

    companion object {
        val EMPTY = SherpaTranscript("")

        /**
         * Turns SenseVoice's `<|en|>` token into `en`.
         *
         * Anything that does not look like a language code becomes empty rather
         * than being passed on: the first token is a language tag by convention
         * and not by guarantee, and a bogus code would pick the wrong
         * punctuation with more confidence than no code at all.
         */
        fun languageCode(raw: String?): String {
            val trimmed = raw?.trim()?.removeSurrounding("<|", "|>")?.trim().orEmpty()
            return trimmed.takeIf { it.length in 2..3 && it.all(Char::isLetter) }
                ?.lowercase()
                .orEmpty()
        }
    }
}

/**
 * Some attention-based models occasionally return no tokens for a longer
 * waveform even though shorter speech from the same recording is recognized.
 * Retry only that empty chunk as two smaller streams; successful chunks never
 * pay the extra inference cost.
 */
internal object SherpaEmptyChunkRecovery {
    private const val MIN_RETRY_SECONDS = 6

    fun decode(
        samples: FloatArray,
        decodeOnce: (FloatArray) -> SherpaTranscript,
    ): SherpaTranscript {
        val firstAttempt = decodeOnce(samples)
        if (firstAttempt.text.isNotEmpty() ||
            samples.size <= MIN_RETRY_SECONDS * SherpaLongAudio.SAMPLE_RATE
        ) {
            return firstAttempt
        }

        val midpoint = samples.size / 2
        return decodeOnce(samples.copyOfRange(0, midpoint))
            .append(decodeOnce(samples.copyOfRange(midpoint, samples.size)), deduplicateOverlap = false)
    }
}
