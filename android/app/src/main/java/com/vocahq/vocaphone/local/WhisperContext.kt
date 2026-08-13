package com.vocahq.vocaphone.local

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
        quality: TranscriptionQuality,
        prompt: String,
    ): LocalTranscription =
        withContext(scope.coroutineContext) {
            check(pointer != 0L) { "Whisper context has been released" }
            val status = WhisperLib.fullTranscribe(
                pointer,
                WhisperCpuConfig.preferredThreadCount,
                samples,
                if (language == "auto") "auto" else language,
                quality.whisperBeamSize,
                quality.whisperTemperatureFallback,
                WhisperCpuConfig.whisperAudioContext(samples.size),
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
                // Only meaningful when "auto" was asked for; otherwise it echoes
                // the request back, which is the same answer either way.
                language = WhisperLib.getDetectedLanguage(pointer),
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
    val preferredThreadCount: Int
        get() = whisperThreadCount(Runtime.getRuntime().availableProcessors())

    /**
     * Whisper's encoder is the dominant cost on phones. Keep two cores free for
     * Android and the UI, but let an eight-core POCO-class device use six for
     * the actual model pass; capping it at four leaves sustained CPU throughput
     * unused and makes even greedy decoding feel stalled.
     */
    internal fun whisperThreadCount(availableProcessors: Int): Int =
        (availableProcessors - 2).coerceIn(2, 6)

    /** 20 ms of audio at 16 kHz, which is one unit of whisper's encoder window. */
    private const val SAMPLES_PER_AUDIO_CONTEXT = 320

    /** Whisper's own window: 1500 units, or the full thirty seconds. */
    private const val FULL_AUDIO_CONTEXT = 1500

    /**
     * Below roughly this much context the decoder degenerates whatever the audio
     * length, so short dictations stop here rather than shrinking to fit.
     */
    private const val MINIMUM_AUDIO_CONTEXT = 448

    /** How much context to ask for beyond the audio itself. */
    private const val AUDIO_CONTEXT_MARGIN = 1.5

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
     * wrong — so this asks for half as much context again as the audio needs, and
     * never less than [MINIMUM_AUDIO_CONTEXT]. Past twenty seconds the full window
     * is the smaller ask, and long recordings whisper already splits into
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
