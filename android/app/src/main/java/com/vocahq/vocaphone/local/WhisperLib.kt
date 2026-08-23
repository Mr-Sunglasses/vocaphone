package com.vocahq.vocaphone.local

import android.util.Log

internal class WhisperLib {
    companion object {
        /**
         * ggml CPU backends for arm64, fastest instruction set first.
         *
         * Only arm64 builds these; every other ABI has the backend compiled in,
         * so finding none here is normal rather than a failure. The names come
         * from ggml's own Android variant list.
         *
         * This replaces a chain that tried whole whisper libraries by name and
         * treated `UnsatisfiedLinkError` as "unsupported CPU". It could not have
         * worked: the libraries all shared one `libggml-cpu.so` so they ran the
         * same kernels, and a CPU missing an instruction set still links — it
         * dies on SIGILL once decoding reaches the instruction. Selection now
         * happens in [registerBackend], where ggml checks CPU features before
         * running any of the backend's code.
         */
        private val CPU_BACKENDS = listOf(
            "ggml-cpu-android_armv9.2_2",
            "ggml-cpu-android_armv9.2_1",
            "ggml-cpu-android_armv9.0_1",
            "ggml-cpu-android_armv8.6_1",
            "ggml-cpu-android_armv8.2_2",
            "ggml-cpu-android_armv8.2_1",
            "ggml-cpu-android_armv8.0_1",
        )

        init {
            System.loadLibrary("whisper")
            // Loading is what makes a backend resolvable by name; registering is
            // what decides whether this CPU may use it. Stopping at the first one
            // ggml accepts leaves the fastest supported tier in place.
            var registered = false
            for (backend in CPU_BACKENDS) {
                if (registered) break
                val loaded = try {
                    System.loadLibrary(backend)
                    true
                } catch (_: UnsatisfiedLinkError) {
                    false // Not built for this ABI.
                }
                if (loaded) registered = registerBackend("lib$backend.so")
            }
            Log.d("VocaPhoneWhisper", "Loaded whisper, tuned CPU backend: $registered")
        }

        /** @return whether ggml accepted this backend for the current CPU. */
        external fun registerBackend(soname: String): Boolean

        external fun initContext(modelPath: String): Long
        external fun freeContext(contextPtr: Long)
        /**
         * @param translate whether to run whisper's translate task, whose only
         *   trained target is English.
         * @param beamSize a beam search width, or zero for greedy sampling.
         * @param audioContext the encoder window in 20 ms units, or zero for
         *   whisper's full thirty-second default.
         * @param prompt vocabulary to bias the decoder toward; empty for none.
         * @return zero on success, or whisper's own negative status on failure.
         */
        external fun fullTranscribe(
            contextPtr: Long,
            numThreads: Int,
            audioData: FloatArray,
            language: String,
            translate: Boolean,
            beamSize: Int,
            temperatureIncrement: Float,
            audioContext: Int,
            prompt: String,
        ): Int
        /** The language actually decoded, or empty when the model reported none. */
        external fun getDetectedLanguage(contextPtr: Long): String

        external fun getTextSegmentCount(contextPtr: Long): Int
        external fun getTextSegment(contextPtr: Long, index: Int): String
        external fun getSystemInfo(): String
    }
}
