package com.vocahq.vocaphone.ui

import com.vocahq.vocaphone.grammar.GrammarFixtures
import com.vocahq.vocaphone.writing.WritingCheck
import com.vocahq.vocaphone.writing.WritingFixtures
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Writing check screen's two decisions: whether to check, and when to stop. */
class WritingCheckScreenTest {
    private val checker = WritingCheck(WritingFixtures.rules)
    private val english: Set<String> by lazy {
        File(GrammarFixtures.root, "../keyboard/en.txt").readLines().map { it.trim().lowercase() }.toSet()
    }

    @Test
    fun frenchIsNotChecked() {
        val french = "Je sais dont il parle."
        // The English rules would offer "don't" here: the language test is
        // what keeps the screen from suggesting it.
        assertTrue(checker.check(french).suggestions.any { it.shownReplacement == "don't" })
        assertFalse(writingCheckApplies(french) { it in english })
        assertFalse(writingCheckApplies("C'est le livre dont elle parle.") { it in english })
    }

    @Test
    fun englishIsChecked() {
        assertTrue(writingCheckApplies("I dont think this is the right way to do it.") { it in english })
        assertTrue(writingCheckApplies("dont worry") { it in english })
    }

    @Test
    fun textWithoutLettersIsNotChecked() {
        assertFalse(writingCheckApplies("12 + 30 = 42") { it in english })
    }

    @Test
    fun cancellingStopsAskingTheModel() = runBlocking {
        val calls = AtomicInteger()
        lateinit var job: Job
        job = launch(Dispatchers.Default, start = CoroutineStart.LAZY) {
            checkUntilCancelled(
                checker,
                "The first sentence is here. The second one follows. A third comes last.",
                WritingCheck.Model { sentence ->
                    calls.incrementAndGet()
                    job.cancel()
                    sentence
                },
                WritingCheck.Options(),
            )
        }
        job.join()
        assertTrue(job.isCancelled)
        assertEquals(1, calls.get())
    }

    @Test
    fun cancellingDuringTheWaitSkipsTheRetry() = runBlocking {
        val calls = AtomicInteger()
        val job = launch(Dispatchers.Default) {
            // The model is still loading: every sentence comes back null.
            checkUntilCancelled(checker, "One short sentence.", { calls.incrementAndGet(); null }, WritingCheck.Options(), retryMillis = 60_000)
        }
        while (calls.get() == 0) Thread.sleep(5)
        job.cancel()
        job.join()
        assertEquals(1, calls.get())
    }

    @Test
    fun aModelStillLoadingIsAskedOnceMore() = runBlocking {
        val calls = AtomicInteger()
        val report = checkUntilCancelled(checker, "One short sentence.", { calls.incrementAndGet(); null }, WritingCheck.Options(), retryMillis = 1)
        assertEquals(2, calls.get())
        assertTrue(report.modelPending)
    }
}
