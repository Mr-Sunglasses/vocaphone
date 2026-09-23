package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.TranscriptionQuality
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext

/** One serialized whisper.cpp context; the native context is not concurrency-safe. */
internal class WhisperContext private constructor(private var pointer: Long) {
    private val scope = CoroutineScope(
        Executors.newSingleThreadExecutor().asCoroutineDispatcher(),
    )

    suspend fun transcribe(
        samples: FloatArray,
        language: String,
        translateTo: String,
        quality: TranscriptionQuality,
        prompt: String,
        cropAudioContext: Boolean,
        threads: Int,
    ): LocalTranscription =
        withContext(scope.coroutineContext) {
            check(pointer != 0L) { "Whisper context has been released" }
            val status = WhisperLib.fullTranscribe(
                pointer,
                threads,
                samples,
                if (language == "auto") "auto" else language,
                translateTo.isNotEmpty(),
                quality.whisperBeamSize,
                quality.whisperTemperatureIncrement,
                if (cropAudioContext) WhisperCpuConfig.whisperAudioContext(samples.size) else 0,
                prompt,
            )
            // A failed decode returns no segments, which would otherwise be
            // reported as an empty transcript — as though the microphone had
            // heard nothing rather than the model having run out of room.
            check(status == 0) {
                "The on-device model could not decode this recording. " +
                    "Try the Fast or Balanced accuracy setting, or a smaller model."
            }
            LocalTranscription(
                text = buildString {
                    repeat(WhisperLib.getTextSegmentCount(pointer)) { index ->
                        append(WhisperLib.getTextSegment(pointer, index))
                    }
                }.trim(),
                // Detection is meaningful only for Automatic. With an explicit
                // selection, the user's requested output language remains the
                // contract even if the engine reports something contradictory.
                // Translating overrides both: the detected language is the one
                // that was spoken, and the text on screen is the target.
                language = ModelLanguageSupport.outputLanguage(
                    requested = language,
                    reported = WhisperLib.getDetectedLanguage(pointer),
                    translateTo = translateTo,
                ),
            )
        }

    suspend fun release() = withContext(scope.coroutineContext) {
        if (pointer != 0L) {
            WhisperLib.freeContext(pointer)
            pointer = 0L
        }
    }

    companion object {
        suspend fun create(modelFile: String): WhisperContext? {
            val pointer = WhisperLib.initContext(modelFile)
            return pointer.takeIf { it != 0L }?.let(::WhisperContext)
        }
    }
}

internal object WhisperCpuConfig {
    fun preferredThreadCount(modelID: String): Int = whisperThreadCount(
        availableProcessors = Runtime.getRuntime().availableProcessors(),
        modelID = modelID,
    )

    /**
     * Quantized Tiny through Small finish soon enough to use six workers
     * profitably. Full-precision Small and every larger model sustain the load
     * long enough that recruiting the efficiency cores heats a heterogeneous
     * phone and throttles the following pass. A POCO F1 running the same
     * 6.6-second full-precision Small sample twice measured 20.8/45.9 seconds
     * with six workers and 16.4/18.7 seconds with four.
     *
     * The catalog no longer ships a full-precision build, so today only Large
     * v3 Turbo reaches the lower ceiling. The `-q` test is kept rather than
     * simplified away because it turns on how long the model runs, not on what
     * it is called, and the measurement above is expensive to rediscover.
     */
    internal fun whisperThreadCount(availableProcessors: Int, modelID: String): Int {
        val modelClass = whisperClass(modelID)
        val fullPrecisionSmall = modelClass == 3 && "-q" !in modelID
        val ceiling = if (fullPrecisionSmall || modelClass >= 4) 4 else 6
        return (availableProcessors - 2).coerceIn(2, ceiling)
    }

    /** 20 ms of audio at 16 kHz, which is one unit of whisper's encoder window. */
    private const val SAMPLES_PER_AUDIO_CONTEXT = 320

    /** Whisper's own window: 1500 units, or the full thirty seconds. */
    private const val FULL_AUDIO_CONTEXT = 1500

    /**
     * Below roughly this much context the decoder degenerates whatever the audio
     * length, so short dictations stop here rather than shrinking to fit.
     */
    private const val MINIMUM_AUDIO_CONTEXT = 768

    /** How much context to ask for beyond the audio itself. */
    private const val AUDIO_CONTEXT_MARGIN = 2.0

    /**
     * The encoder window to ask for, or zero to leave whisper's default.
     *
     * Whisper pads every recording to thirty seconds and encodes all of it, so a
     * two-second dictation costs a phone exactly as much as a full window — on an
     * older device that padding is most of the wait. Cropping the window to the
     * audio recovers nearly all of it.
     *
     * The margin is what makes this safe rather than merely fast. Sized close to
     * the speech, the decoder falls into a repetition loop, and the temperature
     * retries that follow leave the dictation both slower than it started and
     * wrong — so this asks for twice as much context as the audio needs, and never
     * less than [MINIMUM_AUDIO_CONTEXT]. Past fifteen seconds the full window is
     * the smaller ask, and long recordings whisper already splits into
     * thirty-second windows are left exactly as they were.
     */
    internal fun whisperAudioContext(sampleCount: Int): Int {
        val units = sampleCount.toDouble() / SAMPLES_PER_AUDIO_CONTEXT * AUDIO_CONTEXT_MARGIN
        val requested = ceil(units).toInt().coerceAtLeast(MINIMUM_AUDIO_CONTEXT)
        return if (requested >= FULL_AUDIO_CONTEXT) 0 else requested
    }

    /** sherpa uses ONNX Runtime's pool; fewer sustained workers avoid POCO-class thermal throttling. */
    val preferredSherpaThreadCount: Int
        get() = Runtime.getRuntime().availableProcessors().coerceIn(2, 4)
}
