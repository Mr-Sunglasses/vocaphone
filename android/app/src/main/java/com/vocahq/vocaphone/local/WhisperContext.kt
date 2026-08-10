package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.audio.CaptureFormat
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext

/** One serialized whisper.cpp context; the native context is not concurrency-safe. */
internal class WhisperContext private constructor(private var pointer: Long) {
    private val scope = CoroutineScope(
        Executors.newSingleThreadExecutor().asCoroutineDispatcher(),
    )

    suspend fun transcribe(samples: FloatArray, language: String): String =
        withContext(scope.coroutineContext) {
            check(pointer != 0L) { "Whisper context has been released" }
            WhisperLib.fullTranscribe(
                pointer,
                WhisperCpuConfig.preferredThreadCount,
                samples,
                if (language == "auto") "auto" else language,
            )
            buildString {
                repeat(WhisperLib.getTextSegmentCount(pointer)) { index ->
                    append(WhisperLib.getTextSegment(pointer, index))
                }
            }.trim()
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
        get() = (Runtime.getRuntime().availableProcessors() - 2).coerceIn(2, 6)

    /** sherpa uses ONNX Runtime's pool; fewer sustained workers avoid POCO-class thermal throttling. */
    val preferredSherpaThreadCount: Int
        get() = Runtime.getRuntime().availableProcessors().coerceIn(2, 4)
}
