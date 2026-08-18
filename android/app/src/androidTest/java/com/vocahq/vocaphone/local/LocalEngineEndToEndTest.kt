package com.vocahq.vocaphone.local

import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import com.vocahq.vocaphone.audio.SpeechAudioConditioning
import java.io.File
import kotlin.time.measureTime
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Downloads a real pinned model onto the device and transcribes real audio with
 * it, which is the only way to prove the native engine, the pins and the
 * verification markers agree with each other.
 *
 * Opt-in, because it needs the network and pulls tens of megabytes:
 *
 *     ./gradlew :app:connectedDebugAndroidTest \
 *       -Pandroid.testInstrumentationRunnerArguments.localModelE2E=true
 */
class LocalEngineEndToEndTest {
    /** Model storage belongs to the app under test. */
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    /** The sample wav is packaged in the test APK, not the app. */
    private val testContext = InstrumentationRegistry.getInstrumentation().context

    @Test
    fun aPinnedWhisperModelDownloadsVerifiesAndTranscribes() = runBlocking {
        assumeTrue(
            "set -Pandroid.testInstrumentationRunnerArguments.localModelE2E=true to run",
            InstrumentationRegistry.getArguments().getString("localModelE2E") == "true",
        )
        val manager = LocalModelManager(context)
        val model = requireNotNull(LocalModelCatalog.find("tiny-q5_1"))

        manager.download(model)
        assertTrue("download did not report success", manager.isDownloaded(model.id))

        val directory = manager.directoryFor(model)
        // The cheap path must accept what the digest path just committed.
        LocalModelIntegrity.verifySizes(model, directory)
        assertTrue(File(directory, LocalModelIntegrity.VERIFIED_MARKER).isFile)

        val transcript = manager.transcribe(speech(), model.id, "en").text
        assertTrue("empty transcript from $directory", transcript.isNotBlank())
        assertTrue(
            "unexpected transcript: $transcript",
            transcript.lowercase().contains("yellow lamps"),
        )

        // A second pass must reuse the loaded context rather than reloading.
        assertEquals(transcript, manager.transcribe(speech(), model.id, "en").text)
    }

    /**
     * Repeatable physical-device timing for a model that is already downloaded
     * in the app under test. This deliberately does not assert a duration: the
     * same model spans phones with radically different CPUs, while the log gives
     * us comparable numbers for the same audio before and after a change.
     *
     *     ./gradlew :app:connectedFullDebugAndroidTest \
     *       -Pandroid.testInstrumentationRunnerArguments.localModelBenchmark=small
     */
    @Test
    fun anInstalledWhisperModelTranscribesReferenceAudio() = runBlocking {
        val modelID = InstrumentationRegistry.getArguments()
            .getString("localModelBenchmark")
            .orEmpty()
        assumeTrue(
            "set localModelBenchmark to an installed Whisper model ID",
            modelID.isNotEmpty(),
        )
        val manager = LocalModelManager(context)
        val model = requireNotNull(LocalModelCatalog.find(modelID))
        require(model.engine == LocalModelEngine.WHISPER) { "$modelID is not a Whisper model" }
        manager.refresh()
        assumeTrue("$modelID is not downloaded in the target app", manager.isDownloaded(model.id))

        val arguments = InstrumentationRegistry.getArguments()
        val threads = arguments.getString("localModelBenchmarkThreads")
            ?.toIntOrNull()
            ?: WhisperCpuConfig.preferredThreadCount(model.id)
        val audio = SpeechAudioConditioning.condition(speech())
        val audioContext = arguments.getString("localModelBenchmarkContext")
            ?.toIntOrNull()
            ?: if (model.cropsAudioContext) WhisperCpuConfig.whisperAudioContext(audio.size) else 0
        val pointer = WhisperLib.initContext(
            File(manager.directoryFor(model), model.primaryFile.path).absolutePath,
        )
        check(pointer != 0L) { "Could not load ${model.displayName}" }
        try {
            repeat(2) { run ->
                val elapsed = measureTime {
                    check(
                        WhisperLib.fullTranscribe(
                            pointer,
                            threads,
                            audio,
                            "en",
                            0,
                            1f,
                            audioContext,
                            "",
                        ) == 0,
                    ) { "${model.displayName} could not decode the reference audio" }
                }
                val transcript = buildString {
                    repeat(WhisperLib.getTextSegmentCount(pointer)) { index ->
                        append(WhisperLib.getTextSegment(pointer, index))
                    }
                }.trim()
                assertTrue("empty transcript from ${model.displayName}", transcript.isNotBlank())
                assertTrue(
                    "unexpected transcript: $transcript",
                    transcript.lowercase().contains("yellow lamps"),
                )
                Log.i(
                    "VocaPhoneBenchmark",
                    "${model.id} run ${run + 1}: ${elapsed.inWholeMilliseconds} ms; " +
                        "threads=$threads; audio_ctx=$audioContext; $transcript",
                )
            }
        } finally {
            WhisperLib.freeContext(pointer)
        }
    }

    /**
     * 16 kHz mono PCM, as the recorder produces it. The reference transcription
     * is "after early nightfall the yellow lamps would light up here and there
     * the squalid quarter of the brothels".
     */
    private fun speech(): FloatArray {
        val bytes = testContext.assets.open(SAMPLE).use { it.readBytes() }
        val pcm = bytes.drop(44)
        val samples = FloatArray(pcm.size / 2)
        for (index in samples.indices) {
            val low = pcm[index * 2].toInt() and 0xFF
            val high = pcm[index * 2 + 1].toInt()
            samples[index] = ((high shl 8) or low).toShort() / 32_768f
        }
        return samples
    }

    private companion object {
        const val SAMPLE = "local-engine-sample.wav"
    }
}
