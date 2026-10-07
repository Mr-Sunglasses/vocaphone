package com.vocahq.vocaphone.dictation

import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class LocalTranscriptionCancelTest {

    private fun recording(): File =
        File.createTempFile("dictation", ".wav").apply { writeBytes(ByteArray(44)) }

    @Test
    fun `a cancelled dictation discards its recording and records no failure`() = runTest {
        val wav = recording()
        val failures = mutableListOf<Throwable>()
        val decoding = CompletableDeferred<Unit>()
        var cancelled = false
        val job = launch {
            try {
                attemptLocalTranscription(
                    wavFile = wav,
                    ownsAudio = true,
                    attempt = {
                        decoding.complete(Unit)
                        awaitCancellation()
                    },
                    onFailure = { failures += it },
                )
            } catch (error: CancellationException) {
                cancelled = true
                throw error
            }
        }
        runCurrent()
        assertTrue(decoding.isCompleted)

        job.cancelAndJoin()

        assertTrue("the cancellation must reach the pipeline", cancelled)
        assertTrue(failures.isEmpty())
        assertFalse(wav.exists())
    }

    /** An engine that reports the cancel as its own error is still a cancel. */
    @Test
    fun `an engine error raised by the cancel is not a failure`() = runTest {
        val wav = recording()
        val failures = mutableListOf<Throwable>()
        val job = launch {
            attemptLocalTranscription(
                wavFile = wav,
                ownsAudio = true,
                attempt = {
                    try {
                        awaitCancellation()
                    } finally {
                        throw IllegalStateException("The on-device model could not decode this recording.")
                    }
                },
                onFailure = { failures += it },
            )
        }
        runCurrent()

        job.cancelAndJoin()

        assertTrue(failures.isEmpty())
        assertFalse(wav.exists())
    }

    @Test
    fun `a cancelled retry keeps the recording history owns`() = runTest {
        val wav = recording()
        val failures = mutableListOf<Throwable>()
        val job = launch {
            attemptLocalTranscription(
                wavFile = wav,
                ownsAudio = false,
                attempt = { awaitCancellation() },
                onFailure = { failures += it },
            )
        }
        runCurrent()

        job.cancelAndJoin()

        assertTrue(failures.isEmpty())
        assertTrue(wav.exists())
        wav.delete()
    }

    @Test
    fun `a real failure is still reported and keeps the recording for retry`() = runTest {
        val wav = recording()
        val failures = mutableListOf<Throwable>()
        val problem = IllegalStateException("Could not load Whisper Base")

        attemptLocalTranscription(
            wavFile = wav,
            ownsAudio = true,
            attempt = { throw problem },
            onFailure = { failures += it },
        )

        assertEquals(listOf<Throwable>(problem), failures)
        assertTrue(wav.exists())
        wav.delete()
    }
}
