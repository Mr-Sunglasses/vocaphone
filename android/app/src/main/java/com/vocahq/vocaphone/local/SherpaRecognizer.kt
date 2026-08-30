package com.vocahq.vocaphone.local

import com.k2fsa.sherpa.onnx.OfflineCanaryModelConfig
import com.k2fsa.sherpa.onnx.OfflineDolphinModelConfig
import com.k2fsa.sherpa.onnx.FeatureConfig
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
    /**
     * Whether this recognizer was built to translate, which changes how a
     * recording too long for one decode may be cut up. See [transcribe].
     */
    private val translating: Boolean = false,
) {
    /**
     * Decodes the whole recording, in windows if it is longer than one decode
     * should be.
     *
     * Those windows are where translation and transcription part company. Each
     * window retains a little of the one before it so that a word on the
     * boundary survives, and the merger matches the repeated words and removes
     * them. That second half only works if the same audio returns the same
     * words, which a transcriber promises and a translator does not: the
     * retained audio is translated again inside a different sentence and comes
     * back worded differently, so there is nothing to pair.
     *
     * Left on, the merger would then be matching text it was never able to
     * align, and the only thing it can still find is a phrase the speaker
     * genuinely said twice — which it would delete. A translated seam is
     * therefore left exactly as it decoded. The audio overlap stays: almost all
     * of it is the measured quiet run the boundary was found in, which
     * duplicates nothing, and where the boundary was misjudged a word repeated
     * beats a word lost.
     */
    fun transcribe(samples: FloatArray): SherpaTranscript {
        var transcript = SherpaTranscript.EMPTY
        var previousEnd = 0
        var loudestSoFar = 0.0
        SherpaLongAudio.chunks(samples).forEach { chunk ->
            // Whether a short empty answer is ordinary is a question about the
            // audio this window did not inherit from the one before it. A final
            // window that is only the retained overlap has nothing new in it,
            // and an empty answer there is correct. A final window carrying a
            // whole further sentence is the reported failure, and it is that
            // whether or not an earlier window already produced text -- judging
            // it by the transcript so far is what let a closing sentence
            // disappear behind a successful opening one.
            val newRegion = SherpaLongAudio.newRegion(samples, chunk, previousEnd)
            val newRegionLevel = SherpaLongAudio.loudestFrame(newRegion)
            val carriesNewSpeech = SherpaLongAudio.carriesRecoverableSpeech(
                newRegion = newRegion,
                inheritsAudio = chunk.overlapsPrevious,
                loudestFrame = newRegionLevel,
                loudestFrameSoFar = loudestSoFar,
            )
            val chunkResult = SherpaEmptyChunkRecovery.decode(
                samples = samples.copyOfRange(chunk.start, chunk.endExclusive),
                decodeOnce = ::decode,
                deduplicateOverlap = !translating,
                recoverAudibleShortInput = carriesNewSpeech,
            )
            loudestSoFar = maxOf(loudestSoFar, newRegionLevel)
            previousEnd = chunk.endExclusive
            transcript = transcript.append(
                chunkResult,
                deduplicateOverlap = chunk.overlapsPrevious && !translating,
            )
        }
        return transcript.copy(text = transcript.text.trim())
    }

    /** Decodes one bounded window, recovering an empty result with smaller windows. */
    fun transcribeChunk(samples: FloatArray): SherpaTranscript = SherpaEmptyChunkRecovery.decode(
        samples = samples,
        decodeOnce = ::decode,
        deduplicateOverlap = !translating,
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
         * @param translateTo the language to translate into, or empty to
         *   transcribe. Canary is the only family that can honour it; see
         *   [com.vocahq.vocaphone.core.ModelTranslationSupport].
         */
        fun create(
            model: LocalModelDescriptor,
            directory: File,
            language: String,
            threads: Int,
            quality: TranscriptionQuality,
            translateTo: String = "",
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

                // The other three fields stay empty, which is how sherpa-onnx
                // tells the two Moonshine layouts apart.
                SherpaFamily.MOONSHINE_V2 -> OfflineModelConfig(
                    moonshine = OfflineMoonshineModelConfig(
                        encoder = path("encoder_model.ort"),
                        mergedDecoder = path("decoder_model_merged.ort"),
                    ),
                )

                SherpaFamily.DOLPHIN_CTC -> OfflineModelConfig(
                    dolphin = OfflineDolphinModelConfig(model = path("model.int8.onnx")),
                )

                // The one family that can translate. Equal source and target is
                // transcription; differing them is what Canary was trained for,
                // and "auto" has to become a real code because the config has no
                // detection mode — English is the safest guess and the one
                // upstream's own examples use.
                SherpaFamily.CANARY -> {
                    val source = if (language == "auto") "en" else language
                    OfflineModelConfig(
                        canary = OfflineCanaryModelConfig(
                            encoder = path("encoder.int8.onnx"),
                            decoder = path("decoder.int8.onnx"),
                            srcLang = source,
                            tgtLang = translateTo.ifEmpty { source },
                            usePnc = true,
                        ),
                    )
                }

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
                        featConfig = FeatureConfig(dither = family.featureDither),
                        modelConfig = modelConfig,
                        decodingMethod = decodingMethod,
                        maxActivePaths = quality.sherpaMaxActivePaths,
                    ),
                ),
                // Only the families that can honour a target are translating,
                // whatever the caller asked for.
                translating = family.acceptsLanguage && translateTo.isNotEmpty(),
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
 * Retry only that empty chunk as two overlapping smaller streams; successful
 * chunks never pay the extra inference cost.
 */
internal object SherpaEmptyChunkRecovery {

    /**
     * @param deduplicateOverlap false when the caller is translating. The two
     *   halves overlap so the word crossing the centre survives, and matching
     *   the repeat back out only works when the same audio returns the same
     *   words — which is exactly what a translator does not promise.
     * @param recoverAudibleShortInput true when an empty answer here cannot be
     *   the ordinary short trailing overlap. See [SherpaRecognizer.transcribe]
     *   for how that is decided.
     */
    fun decode(
        samples: FloatArray,
        decodeOnce: (FloatArray) -> SherpaTranscript,
        deduplicateOverlap: Boolean = true,
        recoverAudibleShortInput: Boolean = false,
    ): SherpaTranscript {
        // Room tone is the ordinary reason for an empty answer, and the cheapest
        // thing to rule out -- before the first decode, not after it. The scan
        // costs one pass over the samples; a decode of a pause costs inference
        // to be told what the scan already knew. iOS guards in the same place.
        if (SherpaLongAudio.isEffectivelySilent(samples)) return SherpaTranscript.EMPTY

        val firstAttempt = decodeOnce(samples)
        if (firstAttempt.text.isNotEmpty()) return firstAttempt

        // Length is what the split recovers from, so a window that is not long
        // enough to be dropped for its length has nothing there to recover --
        // unless the caller has already established that this window is the
        // whole of what the user has said so far.
        val short =
            samples.size <= SherpaLongAudio.MIN_SUSPECT_CHUNK_SECONDS * SherpaLongAudio.SAMPLE_RATE
        if (!recoverAudibleShortInput && short) return firstAttempt

        // The two extra rungs are for short speech and stay there. A ten-second
        // window is already the length the split recovers from, and padding it
        // by half a second either side buys nothing for the cost of a whole
        // further decode -- so a long window keeps the established ladder and
        // its predictable latency however little has been decoded before it.
        if (short) {
            // A fresh offline stream can recover a nondeterministic no-token
            // answer.
            val repeated = decodeOnce(samples)
            if (repeated.text.isNotEmpty()) return repeated
            // Very short speech can begin or end too close to the encoder
            // context. Half a second either side moves it inside, and is
            // bounded so a recording cannot grow its own decode cost.
            val padding = FloatArray(SherpaLongAudio.SAMPLE_RATE / 2)
            val padded = decodeOnce(padding + samples + padding)
            if (padded.text.isNotEmpty()) return padded
        }

        // Retain context on both sides of the recovery boundary. A plain
        // midpoint split could rescue an empty window while still deleting the
        // word crossing its exact centre. One split and no more: a half-length
        // window that is still empty is not being lost to its length, and
        // subdividing again multiplies the decodes for nothing.
        // Clamped to a quarter of the waveform: without it a recording shorter
        // than the overlap itself hands both halves the entire thing, which is
        // two identical full decodes and no split at all. Only reachable now
        // that a short complete recording gets this far.
        val midpoint = samples.size / 2
        val halfOverlap = (SherpaLongAudio.OVERLAP_MILLIS * SherpaLongAudio.SAMPLE_RATE / 2_000)
            .coerceAtMost(midpoint / 2)
        val leftEnd = (midpoint + halfOverlap).coerceAtMost(samples.size)
        val rightStart = (midpoint - halfOverlap).coerceAtLeast(0)
        return decodeOnce(samples.copyOfRange(0, leftEnd))
            .append(
                decodeOnce(samples.copyOfRange(rightStart, samples.size)),
                deduplicateOverlap = deduplicateOverlap,
            )
    }
}
