import Foundation
import Testing

/// The Writing check screen's two decisions: whether to check, and when to
/// stop. As WritingCheckScreenTest.kt.
struct WritingCheckInAppTests {
    static let checker = WritingCheck(rules: WritingCheckTests.rules)
    static let english: Set<String> = {
        let url = WritingCheckTests.root.appendingPathComponent("keyboard/en.txt")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).map { $0.lowercased() })
    }()

    static func applies(_ text: String) -> Bool {
        WritingCheck.applies(to: text, isDictionaryWord: english.contains)
    }

    static func typed(_ text: String) -> Bool {
        WritingCheck.applies(to: text, isDictionaryWord: english.contains, spelling: WritingCheckTests.spelling)
    }

    /// The more typos, the surer the transcript test was that text was
    /// foreign; the keyboards never checked it. As WritingLanguageTest.kt.
    @Test(arguments: [
        "Teh airport wil be busy",
        "Teh aiport wil be busy tomorow",
        "Recieved teh pacakge, thanks alot Sam",
        "teh meeting wil be tommorow at noon",
        "Pls snd me teh invoce for Acme asap",
        "teh kids plays outsdie evry evening aftr school",
        "kal meeting hai, please send the deck to me",
        // "per" is English too: the foreign-word veto must not count it.
        "The rate is per hour, not per day, and not per week or per month",
        "Are you going to Los Angeles or Las Vegas this year",
    ])
    func typedEnglishWithManyTyposIsStillEnglish(_ text: String) {
        #expect(Self.typed(text))
    }

    @Test(arguments: [
        "Je ne sais pas ce que tu veux dire",
        "Voici la personne dont elle parle souvent.",
        "kal milte hai bro tu aa jana time pe",
        "no se que hacer con mi vida ahora",
        "Ich habe keine Zeit heute abend fur dich",
    ])
    func otherLanguagesTypedInLatinLettersAreStillNotEnglish(_ text: String) {
        #expect(!Self.typed(text))
    }

    @Test func aSlipOfAMarkerWordCountsAsTheMarker() {
        #expect(WritingCheck.markerSlip("teh") == "the")
        #expect(WritingCheck.markerSlip("becuase") == "because")
        #expect(WritingCheck.markerSlip("thier") == "their")
        #expect(WritingCheck.markerSlip("realy") == "really")
        #expect(WritingCheck.markerSlip("the") == nil)
        #expect(WritingCheck.markerSlip("hai") == nil)
    }

    /// Counts model calls from inside a detached task.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    @Test func aFrenchSentenceIsNotChecked() {
        let french = "C'est le livre dont elle parle."
        // The English rules would offer "don't" here: the language test is
        // what keeps the screen from suggesting it.
        #expect(Self.checker.check(french).suggestions.contains { $0.shownReplacement == "don't" })
        #expect(!Self.applies(french))
        #expect(!Self.applies("Voici la personne dont elle parle souvent."))
    }

    @Test func englishIsChecked() {
        #expect(!Self.english.isEmpty)
        #expect(Self.applies("I dont think this is the right way to do it."))
        #expect(Self.applies("dont worry"))
    }

    @Test func aSingleMisspelledWordIsChecked() {
        // What selecting one word and choosing Writing check brings here.
        #expect(Self.applies("recieve"))
        #expect(Self.checker.check("recieve").suggestions.contains { $0.shownReplacement == "receive" })
    }

    @Test func aShortMessageIsChecked() {
        // Too short for the language test to tell: half its words are unknown.
        #expect(!TranscriptRepair.isEnglish("please recieve", isDictionaryWord: Self.english.contains))
        #expect(Self.applies("please recieve"))
        #expect(Self.checker.check("please recieve").suggestions.contains { $0.shownReplacement == "receive" })
    }

    @Test func aBorrowedAccentedWordDoesNotHideTheRestOfAnEnglishSentence() {
        let sentence = "I definately want to visit the café."
        // The transcript test alone calls any accented letter foreign.
        #expect(!TranscriptRepair.isEnglish(sentence, isDictionaryWord: Self.english.contains))
        #expect(Self.applies(sentence))
        #expect(Self.checker.check(sentence).suggestions.contains { $0.shownReplacement == "definitely" })
    }

    @Test func aSentenceWithManyAccentedWordsIsNotEnglish() {
        #expect(!WritingCheck.isEnglish("El niño está en la casa grande") { _ in true })
        #expect(!Self.applies("Ça a été une très belle journée, merci"))
        // One accented word in eight is allowed; the other seven are French.
        #expect(!Self.applies("Je pense que nous irons au café demain"))
    }

    @Test func frenchThatBorrowsNothingButAnAccentIsNotEnglish() {
        // Every word but "C'est" and "café" is in the English list, and the
        // rules would offer "don't" for "dont".
        let french = "C'est le café dont tu as le menu."
        #expect(Self.checker.check(french).suggestions.contains { $0.shownReplacement == "don't" })
        #expect(!Self.applies(french))
    }

    @Test func theRestIsAskedWithoutTheBorrowedWords() {
        var asked = ""
        _ = WritingCheck.isEnglish("we met at the café on monday") { asked = $0; return true }
        #expect(asked == "we met at the on monday")
        _ = WritingCheck.isEnglish("plain english text") { asked = $0; return true }
        #expect(asked == "plain english text")
    }

    @Test func textWithoutLettersIsNotChecked() {
        #expect(!Self.applies("12 + 30 = 42"))
    }

    @Test func cancellingStopsAskingTheModel() async {
        let calls = Counter()
        let report = await Task.detached {
            await Self.checker.checkUntilCancelled(
                "The first sentence is here. The second one follows. A third comes last.",
                model: { sentence in
                    calls.add()
                    withUnsafeCurrentTask { $0?.cancel() }
                    return sentence
                },
                options: WritingCheck.Options()
            )
        }.value
        #expect(report == nil)
        #expect(calls.value == 1)
    }

    @Test func cancellingWhileTheModelLoadsSkipsTheRetry() async {
        let calls = Counter()
        let report = await Task.detached {
            await Self.checker.checkUntilCancelled(
                "One short sentence.",
                model: { _ in
                    calls.add()
                    withUnsafeCurrentTask { $0?.cancel() }
                    return nil
                },
                options: WritingCheck.Options(),
                retryAfter: .seconds(60)
            )
        }.value
        #expect(report == nil)
        #expect(calls.value == 1)
    }

    @Test func aModelStillLoadingIsAskedOnceMore() async {
        let calls = Counter()
        let report = await Self.checker.checkUntilCancelled(
            "One short sentence.",
            model: { _ in
                calls.add()
                return nil
            },
            options: WritingCheck.Options(),
            retryAfter: .milliseconds(1)
        )
        #expect(report?.modelPending == true)
        #expect(calls.value == 2)
    }
}
