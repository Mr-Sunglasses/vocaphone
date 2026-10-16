package com.vocahq.vocaphone.dictation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RetryDecisionTest {

    @Test
    fun aSecondTapOnTheSameRetryIsIgnored() {
        // Running now.
        assertTrue(retryInFlight("a", retrying = "a", pipelineActive = true, queued = emptySet()))
        // Waiting behind another dictation.
        assertTrue(retryInFlight("a", retrying = null, pipelineActive = true, queued = setOf("a")))
    }

    @Test
    fun anotherRecordOrAFinishedRetryStillRuns() {
        assertFalse(retryInFlight("b", retrying = "a", pipelineActive = true, queued = setOf("a")))
        // The pipeline that retried "a" has ended; a new tap is a new retry.
        assertFalse(retryInFlight("a", retrying = "a", pipelineActive = false, queued = emptySet()))
    }

    @Test
    fun aLanguageRejectionIsRetriedInTheLanguageChosenSince() {
        assertEquals("de", retryLanguage(recorded = "hi", errorCode = "language_unsupported", configured = "de"))
        assertEquals("hi", retryLanguage(recorded = "hi", errorCode = "gateway_unreachable", configured = "de"))
        assertEquals("hi", retryLanguage(recorded = "hi", errorCode = null, configured = "de"))
    }
}
