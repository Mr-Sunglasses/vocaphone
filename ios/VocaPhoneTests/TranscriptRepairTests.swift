import Testing

/// Two halves, tested apart: what repair is allowed to remove, and what it is
/// allowed to add. The cases that matter most are the ones asserting it does
/// *neither* — a rule that fires on a word someone meant is worse than the
/// filler it was written to catch.
struct TranscriptRepairTests {

    // MARK: - Fillers

    @Test func hesitationSoundsAreRemoved() {
        #expect(TranscriptRepair.apply("um we should ship it") == "we should ship it")
        #expect(TranscriptRepair.apply("we should uh ship it") == "we should ship it")
        #expect(TranscriptRepair.apply("we should er ship it") == "we should ship it")
        #expect(TranscriptRepair.apply("erm we should ship it") == "we should ship it")
    }

    /// However long the model drew the sound out, it is the same sound.
    @Test func elongatedFillersAreRemoved() {
        #expect(TranscriptRepair.apply("ummmm we should ship it") == "we should ship it")
        #expect(TranscriptRepair.apply("we uhhh should ship it") == "we should ship it")
        #expect(TranscriptRepair.apply("hmmm we should ship it") == "we should ship it")
    }

    /// A filler set off by commas takes both of them with it, or the sentence
    /// is left with a comma that separates nothing.
    @Test func commasAroundAFillerGoWithIt() {
        #expect(TranscriptRepair.apply("I think, um, we should ship") == "I think we should ship")
        #expect(TranscriptRepair.apply("um, we should ship it") == "we should ship it")
    }

    /// The filler goes; the sentence it happened to end does not.
    @Test func aFillerKeepsTheSentenceItClosed() {
        #expect(
            TranscriptRepair.apply("I was thinking. Um. We should ship it")
                == "I was thinking. We should ship it"
        )
    }

    /// These are answers. A transcript that drops them says the opposite of
    /// what was said.
    @Test func affirmationsSurvive() {
        #expect(TranscriptRepair.apply("mhm that works for me") == "mhm that works for me")
        #expect(TranscriptRepair.apply("uh-huh that works") == "uh-huh that works")
        #expect(TranscriptRepair.apply("huh") == "huh")
    }

    /// Every one of these is a real word often enough that removing it needs
    /// judgement about what the speaker meant, which this stage does not have.
    @Test func realWordsAreNeverTreatedAsFillers() {
        let source = "I mean it is like you know actually pretty good so"
        #expect(TranscriptRepair.apply(source) == source)
        #expect(TranscriptRepair.apply("ah well oh dear") == "ah well oh dear")
    }

    /// Quoted, the filler is being talked about rather than said.
    @Test func aQuotedFillerIsKept() {
        #expect(
            TranscriptRepair.apply("he said \"um\" a lot") == "he said \"um\" a lot"
        )
    }

    /// Only in the language that has them: a German "eh" is not a French one.
    @Test func localFillersNeedTheirLanguage() {
        #expect(
            TranscriptRepair.apply("wir sollten ähm morgen liefern", language: "de")
                == "wir sollten morgen liefern"
        )
        // "eh" is Spanish hesitation and an English interjection, so it goes
        // only when the transcript is Spanish.
        #expect(
            TranscriptRepair.apply("eh deberíamos enviarlo", language: "es")
                == "deberíamos enviarlo"
        )
        #expect(TranscriptRepair.apply("eh what was that", language: "en") == "eh what was that")
    }

    /// `um` is German for "at" and `er` is German for "he" and Dutch for
    /// "there". Removing them from those transcripts deletes content, which is
    /// why they are the one part of the filler set that has to know what
    /// language it is looking at.
    @Test func fillersThatAreWordsElsewhereSurvive() {
        #expect(
            TranscriptRepair.apply("wir treffen uns um acht Uhr", language: "de")
                == "wir treffen uns um acht Uhr"
        )
        #expect(
            TranscriptRepair.apply("er kommt in einer Stunde", language: "de")
                == "er kommt in einer Stunde"
        )
        // The unambiguous German filler still goes, and "um" beside it stays.
        #expect(
            TranscriptRepair.apply("wir sollten ähm um acht liefern", language: "de")
                == "wir sollten um acht liefern"
        )
    }

    /// On Automatic nothing has said what the language is, so the sentence has
    /// to. A German one carries no English marker and keeps its "er".
    @Test func automaticNeedsTheSentenceToReadAsEnglish() {
        #expect(
            TranscriptRepair.apply("er kommt in einer Stunde nach Hause")
                == "er kommt in einer Stunde nach Hause"
        )
        #expect(TranscriptRepair.apply("er kommt her") == "er kommt her")
        #expect(TranscriptRepair.apply("um we should ship it that day") == "we should ship it that day")
        // Said explicitly, no marker is needed.
        #expect(TranscriptRepair.apply("um ship it", language: "en") == "ship it")
    }

    /// "err" only looks like a filler after repeated letters are flattened, so
    /// it is caught before that runs.
    @Test func theVerbErrSurvives() {
        #expect(TranscriptRepair.apply("to err is human") == "to err is human")
        #expect(
            TranscriptRepair.apply("errr i am not sure about that")
                == "i am not sure about that"
        )
    }

    /// Repairing a transcript down to nothing is a rule misfiring, not silence.
    @Test func aTranscriptIsNeverRepairedAway() {
        #expect(TranscriptRepair.apply("um", language: "en") == "um")
        #expect(TranscriptRepair.apply("um uh", language: "en") == "um uh")
    }

    // MARK: - False starts

    @Test func aRepeatedPhraseCollapses() {
        #expect(
            TranscriptRepair.apply("we should we should probably ship it")
                == "we should probably ship it"
        )
        #expect(TranscriptRepair.apply("I think I think so") == "I think so")
    }

    /// The second copy is the one the speaker carried on from, so it is the one
    /// that keeps its punctuation.
    @Test func theCompletedCopyIsTheOneKept() {
        #expect(
            TranscriptRepair.apply("we should, we should probably ship")
                == "we should probably ship"
        )
    }

    @Test func aDoubledFunctionWordCollapses() {
        #expect(TranscriptRepair.apply("the the tests are green") == "the tests are green")
        #expect(TranscriptRepair.apply("send it to to me") == "send it to me")
    }

    /// A repeated content word is emphasis the speaker meant.
    @Test func aDoubledContentWordSurvives() {
        #expect(TranscriptRepair.apply("that is very very good") == "that is very very good")
        #expect(TranscriptRepair.apply("no no not that one") == "no no not that one")
        #expect(TranscriptRepair.apply("I love you I love you") == "I love you I love you")
    }

    /// Both of these are ordinary English and both look exactly like a stutter.
    @Test func legitimateDoublesSurvive() {
        #expect(TranscriptRepair.apply("she had had enough") == "she had had enough")
        #expect(
            TranscriptRepair.apply("the thing that that man said") == "the thing that that man said"
        )
        #expect(TranscriptRepair.apply("I gave her her coat") == "I gave her her coat")
        #expect(TranscriptRepair.apply("my my what a surprise") == "my my what a surprise")
        #expect(TranscriptRepair.apply("I can can peaches") == "I can can peaches")
    }

    /// A sentence ended between the copies, so the second starts a new thought.
    @Test func aRepeatAcrossASentenceBoundarySurvives() {
        #expect(TranscriptRepair.apply("I went home. Home is quiet") == "I went home. Home is quiet")
    }

    // MARK: - Marks that are already there

    @Test func spacingAroundMarksIsNormalized() {
        #expect(TranscriptRepair.apply("hello there ,how are you") == "hello there, how are you")
        // Not hostname-shaped — a digit cannot be a top-level domain.
        #expect(
            TranscriptRepair.apply("stop.42 people came to the party")
                == "stop. 42 people came to the party"
        )
    }

    /// A capital after the full stop is a sentence starting, not a domain, and
    /// the space it is missing has to be put back.
    @Test func aCapitalAfterAFullStopIsNotAHostname() {
        #expect(
            TranscriptRepair.apply("I finished the report.Then I left")
                == "I finished the report. Then I left"
        )
        #expect(
            TranscriptRepair.apply("Report.Then I left the office")
                == "Report. Then I left the office"
        )
    }

    /// There are roughly 1,500 top-level domains, so a hostname is recognized
    /// by being written in lowercase throughout rather than by a list of them.
    /// Splitting a dictated address in half is data loss; a missing space is
    /// not.
    @Test func anUnlistedTopLevelDomainIsStillAHostname() {
        #expect(
            TranscriptRepair.apply("visit example.museum for details")
                == "visit example.museum for details"
        )
        #expect(
            TranscriptRepair.apply("read more at my-site.photography today")
                == "read more at my-site.photography today"
        )
        #expect(
            TranscriptRepair.apply("Example.com is the site we use")
                == "Example.com is the site we use"
        )
        // The name in front of the dot carries no signal, so a capitalized one
        // with an unlisted domain has to survive too.
        #expect(
            TranscriptRepair.apply("visit Example.museum for details")
                == "visit Example.museum for details"
        )
        #expect(
            TranscriptRepair.apply("see Acme.photography today")
                == "see Acme.photography today"
        )
        #expect(
            TranscriptRepair.apply("visit NASA.GOV for details")
                == "visit NASA.GOV for details"
        )
        #expect(
            TranscriptRepair.apply("visit example.com/a.b. thanks")
                == "visit example.com/a.b. thanks"
        )
    }

    @Test func runsOfMarksCollapse() {
        #expect(TranscriptRepair.apply("that is great!!!") == "that is great!")
        #expect(TranscriptRepair.apply("really?? I did not know") == "really? I did not know")
        #expect(TranscriptRepair.apply("wait for it....") == "wait for it...")
        // Three is an ellipsis and stays one.
        #expect(TranscriptRepair.apply("wait for it...") == "wait for it...")
    }

    @Test func aSeparatorTouchingATerminatorLoses() {
        #expect(TranscriptRepair.apply("that is all ,. thanks") == "that is all. thanks")
    }

    @Test func orphanedMarksAreDropped() {
        #expect(TranscriptRepair.apply(", we should ship it,") == "we should ship it")
    }

    // MARK: - Marks that are missing

    /// The whole complaint, end to end.
    @Test func aRunOnGetsItsSentencesBack() {
        #expect(
            TranscriptRepair.apply(
                "so i was thinking that um we should we should probably ship it on "
                    + "friday but i dont know if the the tests are green okay lets check"
            )
                == "so i was thinking that we should probably ship it on friday, "
                + "but i dont know if the tests are green. okay, lets check"
        )
    }

    @Test func aConjunctionJoiningTwoClausesTakesAComma() {
        #expect(
            TranscriptRepair.apply("we can ship it on friday but i need the tests")
                == "we can ship it on friday, but i need the tests"
        )
    }

    /// Not every "but" joins two clauses, and not every clause is long enough
    /// to be sure it is one.
    @Test func aConjunctionInsideAClauseIsLeftAlone() {
        #expect(TranscriptRepair.apply("nothing but trouble here") == "nothing but trouble here")
        #expect(TranscriptRepair.apply("slow but steady wins") == "slow but steady wins")
        // "so that" is a phrase, not a new clause.
        #expect(
            TranscriptRepair.apply("i moved the file so that the tests would pass")
                == "i moved the file so that the tests would pass"
        )
    }

    @Test func anOpeningDiscourseMarkerTakesAComma() {
        #expect(TranscriptRepair.apply("okay lets ship it") == "okay, lets ship it")
        #expect(TranscriptRepair.apply("actually i changed my mind") == "actually, i changed my mind")
        #expect(
            TranscriptRepair.apply("however many people come we can fit them")
                == "however many people come we can fit them"
        )
    }

    /// "so" and "well" open a sentence far more often without a comma than
    /// with one, which is why neither is in the list.
    @Test func soAndWellDoNotTakeAComma() {
        #expect(TranscriptRepair.apply("so i was thinking about it") == "so i was thinking about it")
        #expect(TranscriptRepair.apply("well that settles it then") == "well that settles it then")
    }

    /// "okay" after a copula is an adjective describing something, not somebody
    /// starting a sentence.
    @Test func okayAsAnAdjectiveDoesNotSplit() {
        #expect(
            TranscriptRepair.apply("make sure the build is okay before you ship it")
                == "make sure the build is okay before you ship it"
        )
    }

    @Test func questionsGetAQuestionMark() {
        #expect(TranscriptRepair.apply("what time is it") == "what time is it?")
        #expect(TranscriptRepair.apply("do you want coffee") == "do you want coffee?")
        #expect(TranscriptRepair.apply("how many people are coming") == "how many people are coming?")
        // A model that closed a question with a full stop is corrected.
        #expect(TranscriptRepair.apply("can you send it.") == "can you send it?")
    }

    /// A wh-word opening a noun clause is not a question, and the giveaway is a
    /// subject sitting between it and the verb.
    @Test func aStatementStartingWithAWhWordIsNotAQuestion() {
        #expect(TranscriptRepair.apply("what i meant was simple") == "what i meant was simple")
        #expect(
            TranscriptRepair.apply("what the problem is remains unclear")
                == "what the problem is remains unclear"
        )
        #expect(TranscriptRepair.apply("how he did it is unclear") == "how he did it is unclear")
        #expect(
            TranscriptRepair.apply("when i get there i will call you")
                == "when i get there i will call you"
        )
    }

    /// Someone chose the exclamation mark. Repair does not overrule it.
    @Test func anExclamationIsLeftAlone() {
        #expect(TranscriptRepair.apply("what a day!") == "what a day!")
    }

    /// "…but the truth" is an object, not a clause. Only a determiner with room
    /// for a verb after it is one.
    @Test func aDeterminerObjectDoesNotTakeAComma() {
        #expect(
            TranscriptRepair.apply("nothing at all here matters but the truth")
                == "nothing at all here matters but the truth"
        )
        #expect(
            TranscriptRepair.apply("we can ship it on friday but the tests are failing")
                == "we can ship it on friday, but the tests are failing"
        )
    }

    /// A marker only ends the previous sentence when a clause follows it.
    @Test func aStarterWithoutAClauseAfterItDoesNotSplit() {
        #expect(
            TranscriptRepair.apply("the results came back okay and we shipped")
                == "the results came back okay and we shipped"
        )
        #expect(
            TranscriptRepair.apply("i tested the whole thing anyway we can ship")
                == "i tested the whole thing. anyway, we can ship"
        )
    }

    /// "Had I known" inverts exactly the way a question does. The modal further
    /// along is the only thing that tells them apart.
    @Test func anInvertedConditionalIsNotAQuestion() {
        #expect(
            TranscriptRepair.apply("had i known that i would have called")
                == "had i known that i would have called"
        )
        #expect(TranscriptRepair.apply("had you seen the report") == "had you seen the report?")
    }

    /// The mark belongs to the sentence, so it goes inside what wraps it.
    @Test func aQuestionMarkGoesInsideTheQuotes() {
        #expect(TranscriptRepair.apply("\"can you send it\"") == "\"can you send it?\"")
        #expect(TranscriptRepair.apply("\"can you send it.\"") == "\"can you send it?\"")
    }

    /// The two clients build their punctuation classes from one shared set, so
    /// a script whose separator only one of them listed cannot drift.
    @Test func nonLatinSeparatorsAreSpacedToo() {
        #expect(TranscriptRepair.apply("مرحبا ،كيف حالك", language: "ar") == "مرحبا، كيف حالك")
    }

    // MARK: - Spans nothing may touch

    @Test func protectedSpansSurviveEveryStage() {
        #expect(
            TranscriptRepair.apply("um send it to me@example.com at 3.30 today")
                == "send it to me@example.com at 3.30 today"
        )
        #expect(
            TranscriptRepair.apply("open https://example.com/a.b and uh tell me")
                == "open https://example.com/a.b and tell me"
        )
        #expect(TranscriptRepair.apply("it is the 1st of may") == "it is the 1st of may")
    }

    // MARK: - Other scripts

    /// The inference rules are written against how English builds a sentence.
    /// In a script that terminates differently they would do damage, so they
    /// do not run at all.
    @Test func inferenceIsSkippedOutsideLatinLayout() {
        let hindi = "मैं कल बाजार जाऊंगा"
        #expect(TranscriptRepair.apply(hindi, language: "hi") == hindi)
        let japanese = "えーと明日出荷します"
        #expect(TranscriptRepair.apply(japanese, language: "ja") == "明日出荷します")
    }

    /// Another Latin language keeps its layout, and the English trigger words
    /// simply never match — which is the point of choosing English-only words.
    @Test func anotherLatinLanguageIsUntouched() {
        let french = "nous devrions livrer vendredi mais je ne sais pas"
        #expect(TranscriptRepair.apply(french, language: "fr") == french)
    }

    @Test func nothingInMeansNothingOut() {
        #expect(TranscriptRepair.apply(nil).isEmpty)
        #expect(TranscriptRepair.apply("   ").isEmpty)
    }
}
