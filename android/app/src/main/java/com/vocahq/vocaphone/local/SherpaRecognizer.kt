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
    fun transcribe(samples: FloatArray): String {
        var transcript = ""
        SherpaLongAudio.chunks(samples).forEach { chunk ->
            val chunkText = transcribeChunk(samples.copyOfRange(chunk.start, chunk.endExclusive))
            transcript = SherpaTranscriptMerger.append(
                existing = transcript,
                next = chunkText,
                deduplicateOverlap = chunk.overlapsPrevious,
            )
        }
        return transcript.trim()
    }

    /** One already-bounded chunk used by the during-recording pipeline. */
    fun transcribeChunk(samples: FloatArray): String = SherpaEmptyChunkRecovery.decode(
        samples = samples,
        decodeOnce = ::decode,
    )

    private fun decode(samples: FloatArray): String {
        val stream = recognizer.createStream()
        return try {
            stream.acceptWaveform(samples, SherpaLongAudio.SAMPLE_RATE)
            recognizer.decode(stream)
            recognizer.getResult(stream).text.trim()
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

            return SherpaRecognizer(
                OfflineRecognizer(
                    assetManager = null,
                    config = OfflineRecognizerConfig(
                        modelConfig = modelConfig,
                        decodingMethod = "greedy_search",
                    ),
                ),
            )
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

    fun decode(samples: FloatArray, decodeOnce: (FloatArray) -> String): String {
        val firstAttempt = decodeOnce(samples).trim()
        if (firstAttempt.isNotEmpty() || samples.size <= MIN_RETRY_SECONDS * SherpaLongAudio.SAMPLE_RATE) {
            return firstAttempt
        }

        val midpoint = samples.size / 2
        return SherpaTranscriptMerger.append(
            existing = decodeOnce(samples.copyOfRange(0, midpoint)),
            next = decodeOnce(samples.copyOfRange(midpoint, samples.size)),
            deduplicateOverlap = false,
        )
    }
}
