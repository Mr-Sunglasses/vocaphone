package com.vocahq.vocaphone.local

import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelDownloadFailureTest {

    @Test
    fun onlyAPrefixOfThePinnedFileIsResumed() {
        assertEquals(0L, resumeOffset(existingBytes = 0, expectedBytes = 100))
        assertEquals(40L, resumeOffset(existingBytes = 40, expectedBytes = 100))
        // Complete: hashed and accepted without asking the server again.
        assertEquals(100L, resumeOffset(existingBytes = 100, expectedBytes = 100))
        // Longer than the pin cannot be a prefix of it.
        assertEquals(0L, resumeOffset(existingBytes = 101, expectedBytes = 100))
    }

    @Test
    fun aPartialFileIsAppendedToOnlyWhenTheServerResumesExactlyThere() {
        assertTrue(rangeHonoured(offset = 40, code = 206, contentRange = "bytes 40-99/100"))
        assertFalse(rangeHonoured(offset = 40, code = 206, contentRange = "bytes 0-99/100"))
        assertFalse(rangeHonoured(offset = 40, code = 200, contentRange = null))
        assertFalse(rangeHonoured(offset = 40, code = 206, contentRange = null))
        assertFalse(rangeHonoured(offset = 0, code = 206, contentRange = "bytes 0-99/100"))
    }

    @Test
    fun interruptionsKeepThePartialDownloadAndBadBytesDoNot() {
        assertTrue(keepsPartialDownload(IOException("reset"), null))
        assertTrue(keepsPartialDownload(SocketTimeoutException(), null))
        assertTrue(keepsPartialDownload(ModelDownloadHttpException(503), null))
        assertTrue(keepsPartialDownload(null, DownloadCancelReason.TIME_LIMIT))
        assertFalse(keepsPartialDownload(null, DownloadCancelReason.USER))
        assertFalse(keepsPartialDownload(LocalModelIntegrityException("m", "a", "b"), null))
        assertFalse(keepsPartialDownload(ModelDownloadSizeException("f", 1, 2), null))
        assertFalse(keepsPartialDownload(ModelDownloadHttpException(404), null))
        assertFalse(keepsPartialDownload(IllegalStateException(), null))
    }

    @Test
    fun failuresAreDescribedInWordsNotExceptionText() {
        assertEquals(
            "No internet connection. Connect, then tap Retry to continue the download.",
            downloadFailureMessage("Whisper Base", UnknownHostException("huggingface.co")),
        )
        assertEquals(
            "The connection dropped. Tap Retry to continue the download.",
            downloadFailureMessage("Whisper Base", IOException("unexpected end of stream on https://x")),
        )
        assertEquals(
            "The download server is busy. Tap Retry in a few minutes to continue the download.",
            downloadFailureMessage("Whisper Base", ModelDownloadHttpException(503)),
        )
        assertTrue(
            downloadFailureMessage("Whisper Base", LocalModelIntegrityException("m", "a", "b"))
                .startsWith("Whisper Base did not match its checksum"),
        )
        assertEquals(
            "Free up some space.",
            downloadFailureMessage("Whisper Base", LocalModelStorageException("Free up some space.")),
        )
    }
}
