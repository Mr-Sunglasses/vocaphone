package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.TranscriptionQuality
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalEnginePolicyTest {

    @Test
    fun `an unloaded engine always loads`() {
        assertTrue(
            shouldReloadLocalEngine(
                engine = LocalModelEngine.WHISPER,
                loadedModelID = null,
                requestedModelID = "small-q5_1",
                loadedLanguage = null,
                requestedLanguage = "en",
                loadedQuality = null,
                requestedQuality = TranscriptionQuality.BALANCED,
            ),
        )
    }

    @Test
    fun `whisper context survives language and quality changes`() {
        assertFalse(
            shouldReloadLocalEngine(
                engine = LocalModelEngine.WHISPER,
                loadedModelID = "small-q5_1",
                requestedModelID = "small-q5_1",
                loadedLanguage = "en",
                requestedLanguage = "hi",
                loadedQuality = TranscriptionQuality.BALANCED,
                requestedQuality = TranscriptionQuality.ACCURATE,
            ),
        )
    }

    @Test
    fun `whisper context reloads for a different model`() {
        assertTrue(
            shouldReloadLocalEngine(
                engine = LocalModelEngine.WHISPER,
                loadedModelID = "small-q5_1",
                requestedModelID = "base-q5_1",
                loadedLanguage = "en",
                requestedLanguage = "en",
                loadedQuality = TranscriptionQuality.BALANCED,
                requestedQuality = TranscriptionQuality.BALANCED,
            ),
        )
    }

    @Test
    fun `sherpa recognizer reloads for language or quality changes`() {
        assertTrue(
            shouldReloadLocalEngine(
                engine = LocalModelEngine.SHERPA_ONNX,
                loadedModelID = "model",
                requestedModelID = "model",
                loadedLanguage = "en",
                requestedLanguage = "hi",
                loadedQuality = TranscriptionQuality.BALANCED,
                requestedQuality = TranscriptionQuality.BALANCED,
            ),
        )
        assertTrue(
            shouldReloadLocalEngine(
                engine = LocalModelEngine.SHERPA_ONNX,
                loadedModelID = "model",
                requestedModelID = "model",
                loadedLanguage = "en",
                requestedLanguage = "en",
                loadedQuality = TranscriptionQuality.BALANCED,
                requestedQuality = TranscriptionQuality.ACCURATE,
            ),
        )
    }

    @Test
    fun `sherpa recognizer is reused when its identity is unchanged`() {
        assertFalse(
            shouldReloadLocalEngine(
                engine = LocalModelEngine.SHERPA_ONNX,
                loadedModelID = "model",
                requestedModelID = "model",
                loadedLanguage = "en",
                requestedLanguage = "en",
                loadedQuality = TranscriptionQuality.BALANCED,
                requestedQuality = TranscriptionQuality.BALANCED,
            ),
        )
    }
}
