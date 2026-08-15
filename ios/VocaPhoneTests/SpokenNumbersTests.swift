import Testing

/// The feature is one line of description and a minefield of English. These
/// tests are mostly about what must *not* change: a converter that turns "no
/// one" into "no 1" is worse than no converter at all, because the user has to
/// proofread every transcript instead of reading it.
struct SpokenNumbersTests {
    private func converted(_ text: String) -> String {
        SpokenNumbers.digits(in: text)
    }

    // MARK: - The thing it is for

    @Test func aTimeBecomesDigits() {
        #expect(converted("six pm at office") == "6 pm at office")
        #expect(converted("call me at eight am") == "call me at 8 am")
        #expect(converted("the meeting is at eleven o'clock") == "the meeting is at 11 o'clock")
    }

    @Test func plainQuantitiesBecomeDigits() {
        #expect(converted("I need five copies") == "I need 5 copies")
        #expect(converted("zero results") == "0 results")
        #expect(converted("ten people came") == "10 people came")
        #expect(converted("nineteen days later") == "19 days later")
    }

    @Test func compoundNumbersReadAsOneNumber() {
        #expect(converted("twenty three people") == "23 people")
        #expect(converted("twenty-three people") == "23 people")
        #expect(converted("ninety nine problems") == "99 problems")
        #expect(converted("two hundred fifty") == "250")
        #expect(converted("two hundred and fifty") == "250")
        #expect(converted("three thousand") == "3000")
        #expect(converted("twenty five hundred") == "2500")
        #expect(converted("two thousand five hundred") == "2500")
        #expect(converted("one hundred") == "100")
        #expect(converted("two million three thousand five hundred") == "2003500")
    }

    @Test func decimalsAreReadOutDigitByDigit() {
        #expect(converted("three point five hours") == "3.5 hours")
        #expect(converted("three point one four") == "3.14")
        #expect(converted("zero point five") == "0.5")
    }

    /// Case is not information a digit can carry, and a number at the start of a
    /// sentence is still a number.
    @Test func aCapitalisedNumberStillConverts() {
        #expect(converted("Twenty people came.") == "20 people came.")
        #expect(converted("Six pm works.") == "6 pm works.")
    }

    @Test func punctuationAroundANumberSurvives() {
        #expect(converted("at six, then seven.") == "at 6, then 7.")
        #expect(converted("(twenty three)") == "(23)")
        #expect(converted("six!") == "6!")
    }

    // MARK: - The pronoun problem

    /// The case that decides whether this feature is usable at all.
    @Test func aLoneOneStaysAWord() {
        #expect(converted("no one came") == "no one came")
        #expect(converted("one of them is broken") == "one of them is broken")
        #expect(converted("one day I'll get to it") == "one day I'll get to it")
        #expect(converted("that's the one") == "that's the one")
        #expect(converted("one another") == "one another")
        #expect(converted("a one-off thing") == "a one-off thing")
    }

    /// ...but a unit makes it a quantity, and this is the case the user asked
    /// for in the first place.
    @Test func aLoneOneBeforeAUnitConverts() {
        #expect(converted("see you at one pm") == "see you at 1 pm")
        #expect(converted("one hour later") == "1 hour later")
        #expect(converted("one percent of them") == "1 percent of them")
        #expect(converted("one kg of rice") == "1 kg of rice")
    }

    /// Only a plain space attaches the unit. "one, pm" is a list, not a time.
    @Test func aLoneOneKeepsItsWordAcrossPunctuation() {
        #expect(converted("one, pm") == "one, pm")
        #expect(converted("one\npm") == "one\npm")
    }

    /// A "one" inside a larger number was never ambiguous.
    @Test func oneInsideALargerNumberConverts() {
        #expect(converted("twenty one people") == "21 people")
        #expect(converted("one thousand") == "1000")
        #expect(converted("one hundred and one") == "101")
    }

    // MARK: - What it refuses to guess

    /// Two numbers side by side are two numbers. Whatever they meant, "6 7" and
    /// "13" are both worse than what the user actually said.
    @Test func adjacentNumbersThatDoNotComposeAreLeftAlone() {
        #expect(converted("six seven") == "six seven")
        #expect(converted("one two three four") == "one two three four")
        #expect(converted("nineteen eighty four") == "nineteen eighty four")
        #expect(converted("twenty twenty five") == "twenty twenty five")
    }

    /// A spoken time is not a number, and "7 30" is not a time.
    @Test func spokenTimesAreLeftAlone() {
        #expect(converted("seven thirty") == "seven thirty")
        #expect(converted("meet me at seven thirty") == "meet me at seven thirty")
    }

    /// Ordinals are a different transformation with a different set of traps —
    /// "First, let me say" among them — so they are left alone, and so is the
    /// number in front of one.
    @Test func ordinalsAreNeverRewritten() {
        #expect(converted("first of May") == "first of May")
        #expect(converted("second thoughts") == "second thoughts")
        #expect(converted("the twenty first") == "the twenty first")
        #expect(converted("the twenty-first") == "the twenty-first")
        #expect(converted("her thirtieth birthday") == "her thirtieth birthday")
    }

    /// "second" is left out of that guard on purpose: in dictation it is a unit
    /// far more often than an ordinal, and this is the sentence that would pay
    /// for the other choice.
    @Test func secondIsTreatedAsAUnitRatherThanAnOrdinal() {
        #expect(converted("a five second delay") == "a 5 second delay")
        #expect(converted("one second please") == "1 second please")
    }

    /// Number words that open nothing: a run must start with a value, or the
    /// number after it gets swallowed.
    @Test func connectingWordsAreNotNumbersOnTheirOwn() {
        #expect(converted("hundreds of people") == "hundreds of people")
        #expect(converted("that is the point") == "that is the point")
        #expect(converted("you and I") == "you and I")
        #expect(converted("hundred") == "hundred")
    }

    /// A conjunction between two numbers is a conjunction. Only "hundred and"
    /// and "thousand and" continue a number.
    @Test func aConjunctionBetweenNumbersIsNotPartOfThem() {
        #expect(converted("between five and ten") == "between 5 and 10")
        #expect(converted("two and three") == "2 and 3")
        #expect(converted("two hundred and the rest") == "200 and the rest")
    }

    /// A run that runs into the next clause gives the connector back.
    @Test func aTrailingConnectorIsReturnedToTheSentence() {
        #expect(converted("five point Nemo") == "5 point Nemo")
        #expect(converted("at some point five people came") == "at some point 5 people came")
    }

    @Test func impossibleCombinationsAreLeftAsWords() {
        #expect(converted("zero hundred") == "zero hundred")
        #expect(converted("twenty hundred") == "twenty hundred")
        #expect(converted("three thousand two million") == "three thousand two million")
    }

    /// The ceiling exists because a misrecognition can chain scale words
    /// forever, and a fourteen-digit number is never what someone said.
    @Test func theLargestExpressibleNumberConvertsAndNothingBeyondIt() {
        let largest = "nine hundred ninety nine billion "
            + "nine hundred ninety nine million "
            + "nine hundred ninety nine thousand "
            + "nine hundred ninety nine"
        #expect(converted(largest) == "999999999999")
        #expect(SpokenNumbers.maximum == 999_999_999_999)
        // "trillion" is not a scale this knows, so it stays a word rather than
        // becoming a number nobody said.
        #expect(converted("one trillion") == "one trillion")
    }

    // MARK: - Everything else passes through

    @Test func textWithoutNumbersIsUnchanged() {
        let sentence = "Ship the release notes to the team before standup."
        #expect(converted(sentence) == sentence)
        #expect(converted("") == "")
    }

    @Test func digitsAlreadyInTheTextAreUntouched() {
        #expect(converted("call 9876543210 now") == "call 9876543210 now")
        #expect(converted("version 2.1 is out") == "version 2.1 is out")
    }

    /// The word lists are English, so another language has nothing to match.
    @Test func otherLanguagesPassThrough() {
        #expect(converted("मुझे तीन कॉपी चाहिए") == "मुझे तीन कॉपी चाहिए")
        #expect(converted("necesito cinco copias") == "necesito cinco copias")
    }

    /// A number word inside a longer word is part of that word.
    @Test func numbersInsideWordsAreNotNumbers() {
        #expect(converted("someone told me") == "someone told me")
        #expect(converted("anyone can join") == "anyone can join")
        #expect(converted("tennis at noon") == "tennis at noon")
    }

    @Test func lineBreaksEndARun() {
        #expect(converted("twenty\nthree") == "20\n3")
    }
}
