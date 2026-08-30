package com.vocahq.vocaphone.local

import com.vocahq.vocaphone.core.TranscriptionQuality
import org.junit.Assert.assertEquals
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
                requestedModelID = "small-q8_0",
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
                loadedModelID = "small-q8_0",
                requestedModelID = "small-q8_0",
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
                loadedModelID = "small-q8_0",
                requestedModelID = "base-q8_0",
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

    /**
     * Canary bakes source and target into the recognizer together, so changing
     * what it translates into is as much a rebuild as changing the language.
     */
    @Test
    fun `sherpa recognizer reloads for a translation target change`() {
        assertTrue(
            shouldReloadLocalEngine(
                engine = LocalModelEngine.SHERPA_ONNX,
                loadedModelID = "canary-180m-flash",
                requestedModelID = "canary-180m-flash",
                loadedLanguage = "en",
                requestedLanguage = "en",
                loadedQuality = TranscriptionQuality.BALANCED,
                requestedQuality = TranscriptionQuality.BALANCED,
                loadedTranslateTo = "",
                requestedTranslateTo = "de",
            ),
        )
    }

    /**
     * A family with no language field has already had the target resolved away
     * to empty, so a 670 MB Parakeet is never rebuilt for a setting it ignores.
     */
    @Test
    fun `a family that ignores language never reloads for one`() {
        assertFalse(
            shouldReloadLocalEngine(
                engine = LocalModelEngine.SHERPA_ONNX,
                loadedModelID = "parakeet-tdt-0.6b-v3",
                requestedModelID = "parakeet-tdt-0.6b-v3",
                loadedLanguage = "en",
                requestedLanguage = "ru",
                loadedQuality = TranscriptionQuality.BALANCED,
                requestedQuality = TranscriptionQuality.BALANCED,
                languageIsBakedIn = false,
                loadedTranslateTo = "",
                requestedTranslateTo = "ru",
            ),
        )
    }

    /**
     * Streaming stitches overlapping windows by matching the words that come
     * back twice. A translator rewords the overlap, so there is nothing to
     * match — and a sentence spanning two windows is translated as two
     * fragments. Translation takes the whole-file path instead.
     */
    @Test
    fun `streaming is off while translating and on otherwise`() {
        assertTrue(canStreamIncrementally(LocalModelEngine.SHERPA_ONNX, ""))
        assertFalse(canStreamIncrementally(LocalModelEngine.SHERPA_ONNX, "de"))
        // Whisper has never streamed here whatever the target.
        assertFalse(canStreamIncrementally(LocalModelEngine.WHISPER, ""))
        assertFalse(canStreamIncrementally(LocalModelEngine.WHISPER, "en"))
    }

    /** The catalog decides; a stale request can never reach the recognizer. */
    @Test
    fun `a target the model cannot honour resolves away`() {
        val canary = requireNotNull(LocalModelCatalog.find("canary-180m-flash"))
        val parakeet = requireNotNull(LocalModelCatalog.find("parakeet-tdt-0.6b-v3"))
        assertEquals("de", canary.resolveTranslationTarget("de"))
        assertEquals("", canary.resolveTranslationTarget("hi"))
        assertEquals("", canary.resolveTranslationTarget(""))
        assertEquals("", parakeet.resolveTranslationTarget("ru"))
        // Named Automatic is English-as-source, not a translation.
        assertEquals("", canary.resolveTranslationTarget("de", spokenLanguage = "auto"))
        assertEquals("de", canary.resolveTranslationTarget("de", spokenLanguage = "de"))
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

    @Test
    fun `an idle engine is unloaded after two minutes with no users`() {
        assertFalse(idleEngineUnloadDue(users = 1, lastIdleAtMs = 0L, nowMs = 10 * 60 * 1000L))
        assertFalse(idleEngineUnloadDue(users = 0, lastIdleAtMs = 0L, nowMs = 60_000L))
        assertTrue(idleEngineUnloadDue(users = 0, lastIdleAtMs = 0L, nowMs = LOCAL_ENGINE_IDLE_UNLOAD_MS))
        assertTrue(idleEngineUnloadDue(users = 0, lastIdleAtMs = 0L, nowMs = 30_000L, idleMs = 30_000L))
        assertFalse(idleEngineUnloadDue(users = 0, lastIdleAtMs = 0L, nowMs = 10_000L, idleMs = 30_000L))
    }
}
