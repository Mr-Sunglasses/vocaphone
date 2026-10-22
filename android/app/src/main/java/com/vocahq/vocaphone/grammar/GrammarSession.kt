package com.vocahq.vocaphone.grammar

import java.io.Closeable
import java.io.File

/**
 * One ONNX Runtime session over `mindtype_tagger.onnx`, through the JNI bridge
 * in `src/main/cpp/grammar/grammar_jni.c`.
 *
 * The bridge reaches the `libonnxruntime.so` the full and x flavors already
 * ship for sherpa-onnx; there is no second ONNX Runtime in the APK. Every
 * failure is an exception, which [GrammarCorrector] turns into "leave the
 * transcript as it was".
 */
internal class GrammarSession private constructor(private var handle: Long) : Closeable, GrammarTagger.Logits {
    @Synchronized
    override fun run(ids: LongArray, rows: IntArray): Array<FloatArray> {
        check(handle != 0L) { "grammar session is closed" }
        val flat = nativeRun(handle, ids, rows)
        val width = flat.size / rows.size.coerceAtLeast(1)
        return Array(rows.size) { flat.copyOfRange(it * width, (it + 1) * width) }
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) nativeRelease(handle)
        handle = 0L
    }

    companion object {
        /**
         * Loads the bridge. sherpa-onnx's own loader pulls `libonnxruntime` in
         * as a dependency; this one has to ask for it, because the bridge
         * opens it with dlopen rather than linking it.
         */
        private val loaded: Boolean by lazy {
            runCatching {
                System.loadLibrary("onnxruntime")
                System.loadLibrary("vocaphone_grammar")
            }.isSuccess
        }

        fun open(model: File, threads: Int = 2): GrammarSession {
            check(loaded) { "the grammar bridge is not in this build" }
            val handle = nativeCreate(model.absolutePath, threads)
            check(handle != 0L) { "could not create the grammar session" }
            return GrammarSession(handle)
        }

        @JvmStatic private external fun nativeCreate(modelPath: String, threads: Int): Long
        @JvmStatic private external fun nativeRun(handle: Long, ids: LongArray, rows: IntArray): FloatArray
        @JvmStatic private external fun nativeRelease(handle: Long)
    }
}
