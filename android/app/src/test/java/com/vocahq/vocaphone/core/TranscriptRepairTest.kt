package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Two halves, tested apart: what repair is allowed to remove, and what it is
 * allowed to add. The cases that matter most are the ones asserting it does
 * *neither* — a rule that fires on a word someone meant is worse than the
 * filler it was written to catch.
 *
 * Every expectation here is also asserted by the iOS client's
 * `TranscriptRepairTests`. They are meant to stay identical.
 */
class TranscriptRepairTest {

    // region Fillers

    @Test
    fun `hesitation sounds are removed`() {
        assertEquals("we should ship it", TranscriptRepair.apply("um we should ship it"))
        assertEquals("we should ship it", TranscriptRepair.apply("we should uh ship it"))
        assertEquals("we should ship it", TranscriptRepair.apply("we should er ship it"))
        assertEquals("we should ship it", TranscriptRepair.apply("erm we should ship it"))
    }

    /** However long the model drew the sound out, it is the same sound. */
    @Test
    fun `elongated fillers are removed`() {
        assertEquals("we should ship it", TranscriptRepair.apply("ummmm we should ship it"))
        assertEquals("we should ship it", TranscriptRepair.apply("we uhhh should ship it"))
        assertEquals("we should ship it", TranscriptRepair.apply("hmmm we should ship it"))
    }

    /**
     * A filler set off by commas takes both of them with it, or the sentence is
     * left with a comma that separates nothing.
     */
    @Test
    fun `commas around a filler go with it`() {
        assertEquals("I think we should ship", TranscriptRepair.apply("I think, um, we should ship"))
        assertEquals("we should ship it", TranscriptRepair.apply("um, we should ship it"))
    }

    /** The filler goes; the sentence it happened to end does not. */
    @Test
    fun `a filler keeps the sentence it closed`() {
        assertEquals(
            "I was thinking. We should ship it",
            TranscriptRepair.apply("I was thinking. Um. We should ship it"),
        )
    }

    /**
     * These are answers. A transcript that drops them says the opposite of what
     * was said.
     */
    @Test
    fun `affirmations survive`() {
        assertEquals("mhm that works for me", TranscriptRepair.apply("mhm that works for me"))
        assertEquals("uh-huh that works", TranscriptRepair.apply("uh-huh that works"))
        assertEquals("huh", TranscriptRepair.apply("huh"))
    }

    /**
     * Every one of these is a real word often enough that removing it needs
     * judgement about what the speaker meant, which this stage does not have.
     */
    @Test
    fun `real words are never treated as fillers`() {
        val source = "I mean it is like you know actually pretty good so"
        assertEquals(source, TranscriptRepair.apply(source))
        assertEquals("ah well oh dear", TranscriptRepair.apply("ah well oh dear"))
    }

    /** Quoted, the filler is being talked about rather than said. */
    @Test
    fun `a quoted filler is kept`() {
        assertEquals("he said \"um\" a lot", TranscriptRepair.apply("he said \"um\" a lot"))
    }

    /** Only in the language that has them: a German "eh" is not a French one. */
    @Test
    fun `local fillers need their language`() {
        assertEquals(
            "wir sollten morgen liefern",
            TranscriptRepair.apply("wir sollten ähm morgen liefern", "de"),
        )
        // "eh" is Spanish hesitation and an English interjection, so it goes
        // only when the transcript is Spanish.
        assertEquals(
            "deberíamos enviarlo",
            TranscriptRepair.apply("eh deberíamos enviarlo", "es"),
        )
        assertEquals("eh what was that", TranscriptRepair.apply("eh what was that", "en"))
    }

    /**
     * `um` is German for "at" and `er` is German for "he" and Dutch for
     * "there". Removing them from those transcripts deletes content, which is
     * why they are the one part of the filler set that has to know what
     * language it is looking at.
     */
    @Test
    fun `fillers that are words elsewhere survive`() {
        assertEquals(
            "wir treffen uns um acht Uhr",
            TranscriptRepair.apply("wir treffen uns um acht Uhr", "de"),
        )
        assertEquals(
            "er kommt in einer Stunde",
            TranscriptRepair.apply("er kommt in einer Stunde", "de"),
        )
        // The unambiguous German filler still goes, and "um" beside it stays.
        assertEquals(
            "wir sollten um acht liefern",
            TranscriptRepair.apply("wir sollten ähm um acht liefern", "de"),
        )
    }

    /**
     * On Automatic nothing has said what the language is, so the sentence has
     * to. A German one carries no English marker and keeps its "er".
     */
    @Test
    fun `automatic needs the sentence to read as english`() {
        assertEquals(
            "er kommt in einer Stunde nach Hause",
            TranscriptRepair.apply("er kommt in einer Stunde nach Hause"),
        )
        assertEquals("er kommt her", TranscriptRepair.apply("er kommt her"))
        assertEquals(
            "we should ship it that day",
            TranscriptRepair.apply("um we should ship it that day"),
        )
        // Said explicitly, no marker is needed.
        assertEquals("ship it", TranscriptRepair.apply("um ship it", "en"))
    }

    /**
     * "err" only looks like a filler after repeated letters are flattened, so
     * it is caught before that runs.
     */
    @Test
    fun `the verb err survives`() {
        assertEquals("to err is human", TranscriptRepair.apply("to err is human"))
        assertEquals(
            "i am not sure about that",
            TranscriptRepair.apply("errr i am not sure about that"),
        )
    }

    /** Repairing a transcript down to nothing is a rule misfiring, not silence. */
    @Test
    fun `a transcript is never repaired away`() {
        assertEquals("um", TranscriptRepair.apply("um", "en"))
        assertEquals("um uh", TranscriptRepair.apply("um uh", "en"))
    }

    // endregion

    // region False starts

    @Test
    fun `a repeated phrase collapses`() {
        assertEquals(
            "we should probably ship it",
            TranscriptRepair.apply("we should we should probably ship it"),
        )
        assertEquals("I think so", TranscriptRepair.apply("I think I think so"))
    }

    /**
     * The second copy is the one the speaker carried on from, so it is the one
     * that keeps its punctuation.
     */
    @Test
    fun `the completed copy is the one kept`() {
        assertEquals(
            "we should probably ship",
            TranscriptRepair.apply("we should, we should probably ship"),
        )
    }

    @Test
    fun `a doubled function word collapses`() {
        assertEquals("the tests are green", TranscriptRepair.apply("the the tests are green"))
        assertEquals("send it to me", TranscriptRepair.apply("send it to to me"))
    }

    /** A repeated content word is emphasis the speaker meant. */
    @Test
    fun `a doubled content word survives`() {
        assertEquals("that is very very good", TranscriptRepair.apply("that is very very good"))
        assertEquals("no no not that one", TranscriptRepair.apply("no no not that one"))
        assertEquals("I love you I love you", TranscriptRepair.apply("I love you I love you"))
    }

    /** Both of these are ordinary English and both look exactly like a stutter. */
    @Test
    fun `legitimate doubles survive`() {
        assertEquals("she had had enough", TranscriptRepair.apply("she had had enough"))
        assertEquals(
            "the thing that that man said",
            TranscriptRepair.apply("the thing that that man said"),
        )
        assertEquals("I gave her her coat", TranscriptRepair.apply("I gave her her coat"))
        assertEquals("my my what a surprise", TranscriptRepair.apply("my my what a surprise"))
        assertEquals("I can can peaches", TranscriptRepair.apply("I can can peaches"))
    }

    /** A sentence ended between the copies, so the second starts a new thought. */
    @Test
    fun `a repeat across a sentence boundary survives`() {
        assertEquals(
            "I went home. Home is quiet",
            TranscriptRepair.apply("I went home. Home is quiet"),
        )
    }

    // endregion

    // region Marks that are already there

    @Test
    fun `spacing around marks is normalized`() {
        assertEquals("hello there, how are you", TranscriptRepair.apply("hello there ,how are you"))
        // Not hostname-shaped — a digit cannot be a top-level domain.
        assertEquals(
            "stop. 42 people came to the party",
            TranscriptRepair.apply("stop.42 people came to the party"),
        )
    }

    /**
     * A capital after the full stop is a sentence starting, not a domain, and
     * the space it is missing has to be put back.
     */
    @Test
    fun `a capital after a full stop is not a hostname`() {
        assertEquals(
            "I finished the report. Then I left",
            TranscriptRepair.apply("I finished the report.Then I left"),
        )
        assertEquals(
            "Report. Then I left the office",
            TranscriptRepair.apply("Report.Then I left the office"),
        )
    }

    /**
     * There are roughly 1,500 top-level domains, so a hostname is recognized by
     * being written in lowercase throughout rather than by a list of them.
     * Splitting a dictated address in half is data loss; a missing space is not.
     */
    @Test
    fun `an unlisted top-level domain is still a hostname`() {
        assertEquals(
            "visit example.museum for details",
            TranscriptRepair.apply("visit example.museum for details"),
        )
        assertEquals(
            "read more at my-site.photography today",
            TranscriptRepair.apply("read more at my-site.photography today"),
        )
        assertEquals(
            "Example.com is the site we use",
            TranscriptRepair.apply("Example.com is the site we use"),
        )
        // The name in front of the dot carries no signal, so a capitalized one
        // with an unlisted domain has to survive too.
        assertEquals(
            "visit Example.museum for details",
            TranscriptRepair.apply("visit Example.museum for details"),
        )
        assertEquals(
            "see Acme.photography today",
            TranscriptRepair.apply("see Acme.photography today"),
        )
        assertEquals(
            "visit NASA.GOV for details",
            TranscriptRepair.apply("visit NASA.GOV for details"),
        )
        assertEquals(
            "visit example.com/a.b. thanks",
            TranscriptRepair.apply("visit example.com/a.b. thanks"),
        )
    }

    @Test
    fun `runs of marks collapse`() {
        assertEquals("that is great!", TranscriptRepair.apply("that is great!!!"))
        assertEquals("really? I did not know", TranscriptRepair.apply("really?? I did not know"))
        assertEquals("wait for it...", TranscriptRepair.apply("wait for it...."))
        // Three is an ellipsis and stays one.
        assertEquals("wait for it...", TranscriptRepair.apply("wait for it..."))
    }

    @Test
    fun `a separator touching a terminator loses`() {
        assertEquals("that is all. thanks", TranscriptRepair.apply("that is all ,. thanks"))
    }

    @Test
    fun `orphaned marks are dropped`() {
        assertEquals("we should ship it", TranscriptRepair.apply(", we should ship it,"))
    }

    // endregion

    // region Marks that are missing

    /** The whole complaint, end to end. */
    @Test
    fun `a run-on gets its sentences back`() {
        assertEquals(
            "so i was thinking that we should probably ship it on friday, " +
                "but i dont know if the tests are green. okay, lets check",
            TranscriptRepair.apply(
                "so i was thinking that um we should we should probably ship it on " +
                    "friday but i dont know if the the tests are green okay lets check",
            ),
        )
    }

    @Test
    fun `a conjunction joining two clauses takes a comma`() {
        assertEquals(
            "we can ship it on friday, but i need the tests",
            TranscriptRepair.apply("we can ship it on friday but i need the tests"),
        )
    }

    /**
     * Not every "but" joins two clauses, and not every clause is long enough to
     * be sure it is one.
     */
    @Test
    fun `a conjunction inside a clause is left alone`() {
        assertEquals("nothing but trouble here", TranscriptRepair.apply("nothing but trouble here"))
        assertEquals("slow but steady wins", TranscriptRepair.apply("slow but steady wins"))
        // "so that" is a phrase, not a new clause.
        assertEquals(
            "i moved the file so that the tests would pass",
            TranscriptRepair.apply("i moved the file so that the tests would pass"),
        )
    }

    @Test
    fun `an opening discourse marker takes a comma`() {
        assertEquals("okay, lets ship it", TranscriptRepair.apply("okay lets ship it"))
        assertEquals(
            "actually, i changed my mind",
            TranscriptRepair.apply("actually i changed my mind"),
        )
        assertEquals(
            "however many people come we can fit them",
            TranscriptRepair.apply("however many people come we can fit them"),
        )
    }

    /**
     * "so" and "well" open a sentence far more often without a comma than with
     * one, which is why neither is in the list.
     */
    @Test
    fun `so and well do not take a comma`() {
        assertEquals(
            "so i was thinking about it",
            TranscriptRepair.apply("so i was thinking about it"),
        )
        assertEquals(
            "well that settles it then",
            TranscriptRepair.apply("well that settles it then"),
        )
    }

    /**
     * "okay" after a copula is an adjective describing something, not somebody
     * starting a sentence.
     */
    @Test
    fun `okay as an adjective does not split`() {
        assertEquals(
            "make sure the build is okay before you ship it",
            TranscriptRepair.apply("make sure the build is okay before you ship it"),
        )
    }

    @Test
    fun `questions get a question mark`() {
        assertEquals("what time is it?", TranscriptRepair.apply("what time is it"))
        assertEquals("do you want coffee?", TranscriptRepair.apply("do you want coffee"))
        assertEquals(
            "how many people are coming?",
            TranscriptRepair.apply("how many people are coming"),
        )
        // A model that closed a question with a full stop is corrected.
        assertEquals("can you send it?", TranscriptRepair.apply("can you send it."))
    }

    /**
     * A wh-word opening a noun clause is not a question, and the giveaway is a
     * subject sitting between it and the verb.
     */
    @Test
    fun `a statement starting with a wh-word is not a question`() {
        assertEquals("what i meant was simple", TranscriptRepair.apply("what i meant was simple"))
        assertEquals(
            "what the problem is remains unclear",
            TranscriptRepair.apply("what the problem is remains unclear"),
        )
        assertEquals("how he did it is unclear", TranscriptRepair.apply("how he did it is unclear"))
        assertEquals(
            "when i get there i will call you",
            TranscriptRepair.apply("when i get there i will call you"),
        )
    }

    /** Someone chose the exclamation mark. Repair does not overrule it. */
    @Test
    fun `an exclamation is left alone`() {
        assertEquals("what a day!", TranscriptRepair.apply("what a day!"))
    }

    // endregion

    /**
     * "…but the truth" is an object, not a clause. Only a determiner with room
     * for a verb after it is one.
     */
    @Test
    fun `a determiner object does not take a comma`() {
        assertEquals(
            "nothing at all here matters but the truth",
            TranscriptRepair.apply("nothing at all here matters but the truth"),
        )
        assertEquals(
            "we can ship it on friday, but the tests are failing",
            TranscriptRepair.apply("we can ship it on friday but the tests are failing"),
        )
    }

    /** A marker only ends the previous sentence when a clause follows it. */
    @Test
    fun `a starter without a clause after it does not split`() {
        assertEquals(
            "the results came back okay and we shipped",
            TranscriptRepair.apply("the results came back okay and we shipped"),
        )
        assertEquals(
            "i tested the whole thing. anyway, we can ship",
            TranscriptRepair.apply("i tested the whole thing anyway we can ship"),
        )
    }

    /**
     * "Had I known" inverts exactly the way a question does. The modal further
     * along is the only thing that tells them apart.
     */
    @Test
    fun `an inverted conditional is not a question`() {
        assertEquals(
            "had i known that i would have called",
            TranscriptRepair.apply("had i known that i would have called"),
        )
        assertEquals("had you seen the report?", TranscriptRepair.apply("had you seen the report"))
    }

    /** The mark belongs to the sentence, so it goes inside what wraps it. */
    @Test
    fun `a question mark goes inside the quotes`() {
        assertEquals("\"can you send it?\"", TranscriptRepair.apply("\"can you send it\""))
        assertEquals("\"can you send it?\"", TranscriptRepair.apply("\"can you send it.\""))
    }

    /**
     * The two clients build their punctuation classes from one shared set, so a
     * script whose separator only one of them listed cannot drift.
     */
    @Test
    fun `non-latin separators are spaced too`() {
        assertEquals("مرحبا، كيف حالك", TranscriptRepair.apply("مرحبا ،كيف حالك", "ar"))
    }

    // region Spans nothing may touch

    @Test
    fun `protected spans survive every stage`() {
        assertEquals(
            "send it to me@example.com at 3.30 today",
            TranscriptRepair.apply("um send it to me@example.com at 3.30 today"),
        )
        assertEquals(
            "open https://example.com/a.b and tell me",
            TranscriptRepair.apply("open https://example.com/a.b and uh tell me"),
        )
        assertEquals("it is the 1st of may", TranscriptRepair.apply("it is the 1st of may"))
    }

    // endregion

    // region Other scripts

    /**
     * The inference rules are written against how English builds a sentence. In
     * a script that terminates differently they would do damage, so they do not
     * run at all.
     */
    @Test
    fun `inference is skipped outside latin layout`() {
        val hindi = "मैं कल बाजार जाऊंगा"
        assertEquals(hindi, TranscriptRepair.apply(hindi, "hi"))
        assertEquals("明日出荷します", TranscriptRepair.apply("えーと明日出荷します", "ja"))
    }

    /**
     * Another Latin language keeps its layout, and the English trigger words
     * simply never match — which is the point of choosing English-only words.
     */
    @Test
    fun `another latin language is untouched`() {
        val french = "nous devrions livrer vendredi mais je ne sais pas"
        assertEquals(french, TranscriptRepair.apply(french, "fr"))
    }

    @Test
    fun `nothing in means nothing out`() {
        assertEquals("", TranscriptRepair.apply(null))
        assertEquals("", TranscriptRepair.apply("   "))
    }

    // endregion
}
