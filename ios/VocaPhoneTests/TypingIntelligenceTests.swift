import Foundation
import Testing
import UIKit

/// Field traits beyond secrets: a field that turned autocorrection off, and
/// the two features that follow the secret-field rule — swipe and dictation.
struct TypingFieldTraitTests {
    /// Apple's keyboard hides its suggestion bar where a field sets
    /// `autocorrectionType = .no`, and corrects nothing there.
    @Test func autocorrectionOffMeansNoSuggestions() {
        let policy = TypingFieldPolicy.resolve(
            isSecureTextEntry: false,
            contentType: nil,
            keyboardType: .default,
            autocorrectionType: .no
        )
        #expect(!policy.allowsSuggestions)
        // Not a secret: the rest of the keyboard is untouched.
        #expect(policy.allowsTypingIntelligence)
        #expect(policy.allowsSwipeTyping)
        #expect(policy.allowsDictation)
    }

    @Test func otherAutocorrectionTypesKeepSuggestions() {
        for type in [UITextAutocorrectionType.default, .yes] {
            let policy = TypingFieldPolicy.resolve(
                isSecureTextEntry: false,
                contentType: nil,
                keyboardType: .default,
                autocorrectionType: type
            )
            #expect(policy == .allowed)
            #expect(policy.allowsSuggestions)
        }
    }

    @Test func secretsTurnOffSwipeAndDictation() {
        let secure = TypingFieldPolicy.resolve(
            isSecureTextEntry: true, contentType: nil, keyboardType: .default
        )
        #expect(!secure.allowsSwipeTyping)
        #expect(!secure.allowsDictation)
        for contentType in TypingFieldPolicy.sensitiveContentTypes {
            let policy = TypingFieldPolicy.resolve(
                isSecureTextEntry: false, contentType: contentType, keyboardType: .default
            )
            #expect(!policy.allowsSwipeTyping, "\(contentType.rawValue)")
            #expect(!policy.allowsDictation, "\(contentType.rawValue)")
        }
    }

    /// Saying a phone number is reasonable; a number pad is not a secret.
    @Test func aNumberPadStillOffersDictation() {
        let policy = TypingFieldPolicy.resolve(
            isSecureTextEntry: false, contentType: nil, keyboardType: .phonePad
        )
        #expect(policy.allowsDictation)
        #expect(!policy.allowsSwipeTyping)
    }

    /// A secret field that also turned autocorrection off is still a secret.
    @Test func secureEntryOutranksAutocorrectionOff() {
        let policy = TypingFieldPolicy.resolve(
            isSecureTextEntry: true, contentType: nil, keyboardType: .default, autocorrectionType: .no
        )
        #expect(policy.reason == .secureEntry)
        #expect(!policy.allowsDictation)
    }

    @Test func dictateIsSwitchedOffNotRemoved() {
        let open = DictationBarModel.make(DictationContext(state: .idle))
        #expect(open.primary.isEnabled)
        #expect(open.primary.symbol == "mic.fill")

        let closed = DictationBarModel.make(DictationContext(state: .idle, allowsDictation: false))
        #expect(!closed.primary.isEnabled)
        #expect(closed.primary.symbol == "mic.slash.fill")
        #expect(closed.primary.title == DictationBarModel.noDictationHere)
        // The row keeps its shape: suggestions still show beside it.
        let withWords = DictationBarModel.make(DictationContext(
            state: .idle,
            candidates: [TypingCandidate(text: "hello", kind: .completion)],
            allowsDictation: false
        ))
        #expect(withWords.layout == .strip)
    }
}

/// Swipe ranks against the shipped list, which is English. Any other layout
/// gets no swipe rather than an English word.
struct SwipeLanguageTests {
    private static let list = TypingWordList(words: ["hello", "world"], bigrams: [:])

    @Test func theShippedListServesEnglishOnly() {
        #expect(TypingWordList.shippedLanguage == "en")
        for layout in TypingLayout.catalogue {
            #expect(Self.list.serves(layout) == (layout.id == "en"), "\(layout.id)")
        }
    }

    @Test func anEmptyListServesNothing() {
        #expect(!TypingWordList.empty.serves(.fallback))
    }

    /// The day a French list ships, it serves the French layout and only it.
    @Test func aListServesTheLayoutOfItsOwnLanguage() {
        let french = TypingWordList(words: ["bonjour"], bigrams: [:], language: "fr")
        for layout in TypingLayout.catalogue {
            #expect(french.serves(layout) == (layout.id == "fr"), "\(layout.id)")
        }
    }
}

/// Shift over a selection, mirroring the Android keyboard's `CaseCycleTest`.
struct CaseCycleTests {
    @Test func aSingleWordCyclesSentenceUpperLower() {
        #expect(CaseCycle.next("hello") == "Hello")
        #expect(CaseCycle.next("Hello") == "HELLO")
        #expect(CaseCycle.next("HELLO") == "hello")
    }

    @Test func severalWordsCapitaliseOnlyTheFirst() {
        #expect(CaseCycle.next("hello world") == "Hello world")
        #expect(CaseCycle.next("Hello world") == "HELLO WORLD")
        #expect(CaseCycle.next("HELLO WORLD") == "hello world")
        #expect(CaseCycle.next("hello World There") == "Hello world there")
    }

    /// "iPhone" is none of the three derived forms, so it comes back fourth.
    @Test func aMixedOriginalComesBackAfterLower() {
        let original = "iPhone"
        let sentence = CaseCycle.next(original, original: original)
        let upper = CaseCycle.next(sentence, original: original)
        let lower = CaseCycle.next(upper, original: original)
        let restored = CaseCycle.next(lower, original: original)
        #expect([sentence, upper, lower, restored] == ["Iphone", "IPHONE", "iphone", "iPhone"])
    }

    @Test func apostrophesStayInsideTheWord() {
        #expect(CaseCycle.next("don't stop") == "Don't stop")
        #expect(CaseCycle.next("Don't stop") == "DON'T STOP")
        #expect(CaseCycle.next("DON'T STOP") == "don't stop")
        #expect(CaseCycle.next("don\u{2019}t stop") == "Don\u{2019}t stop")
    }

    @Test func leadingPunctuationIsKept() {
        #expect(CaseCycle.next("“hello” there") == "“Hello” there")
        #expect(CaseCycle.next("“Hello” there") == "“HELLO” THERE")
    }

    @Test func textWithNoLettersIsLeftAlone() {
        #expect(CaseCycle.next("123") == "123")
        #expect(CaseCycle.next("") == "")
    }

    /// The next tap carries on only while the last step is still exactly what
    /// sits before the cursor, and nothing after it has moved.
    @Test func aSessionContinuesOnlyWhereItLeftOff() {
        let session = CaseCycleSession(original: "hello", emitted: "Hello", after: " there")
        #expect(session.continues(before: "Say Hello", after: " there"))
        #expect(!session.continues(before: "Say Hello!", after: " there"))
        #expect(!session.continues(before: "Say Hello", after: "there"))
        #expect(!session.continues(before: nil, after: " there"))
        let long = String(repeating: "a", count: CaseCycleSession.continuationLimit + 1)
        let tooLong = CaseCycleSession(original: long, emitted: long, after: nil)
        #expect(!tooLong.continues(before: long, after: nil))
    }

    /// With the setting on, Shift rewrites only a short, single-line
    /// selection with letters in it — small enough that what the host handed
    /// over is all of it.
    @Test func onlyAShortSingleLineSelectionIsRewritten() {
        #expect(SelectionCaseGuard.allows("hello world"))
        #expect(SelectionCaseGuard.allows(String(repeating: "a", count: SelectionCaseGuard.maximumLength)))
        #expect(!SelectionCaseGuard.allows(String(repeating: "a", count: SelectionCaseGuard.maximumLength + 1)))
        #expect(!SelectionCaseGuard.allows("first line\nsecond line"))
        #expect(!SelectionCaseGuard.allows("12 34"))
    }

    /// An address has no sentence case: never in URL, search or email fields.
    @Test func neverInAddressFields() {
        #expect(SelectionCaseGuard.fieldAllows(keyboardType: .default, contentType: nil))
        #expect(SelectionCaseGuard.fieldAllows(keyboardType: nil, contentType: nil))
        #expect(!SelectionCaseGuard.fieldAllows(keyboardType: .URL, contentType: nil))
        #expect(!SelectionCaseGuard.fieldAllows(keyboardType: .webSearch, contentType: nil))
        #expect(!SelectionCaseGuard.fieldAllows(keyboardType: .emailAddress, contentType: nil))
        #expect(!SelectionCaseGuard.fieldAllows(keyboardType: .default, contentType: .URL))
        #expect(!SelectionCaseGuard.fieldAllows(keyboardType: .default, contentType: .emailAddress))
    }

    /// Cut deletes the host's whole selection, so it takes only selections
    /// small enough to trust the keyboard was handed all of.
    @Test func cutAndCopyRefuseALongSelection() {
        #expect(SelectionEditGuard.allows("word"))
        #expect(!SelectionEditGuard.allows(""))
        #expect(!SelectionEditGuard.allows(String(repeating: "a", count: SelectionEditGuard.maximumLength + 1)))
    }
}

/// "12*4=" offers 48. Plain arithmetic, and only where it is unmistakably a sum.
struct InlineArithmeticTests {
    @Test(arguments: [
        ("12*4=", "48"),
        ("1,200/3=", "400"),
        ("2+3*4=", "14"),
        ("(2+3)*4=", "20"),
        ("10/4=", "2.5"),
        ("10/3=", "3.333333"),
        ("7−10=", "-3"),
        ("-5+2=", "-3"),
        ("6×7=", "42"),
        ("9÷3=", "3"),
        ("0.1+0.2=", "0.3"),
        ("1,000*3=", "3,000"),
        ("Total is 12 * 4=", "48"),
        ("Well, 3+4=", "7"),
        ("ok\n5-2=", "3"),
    ])
    func aSumIsAnswered(text: String, answer: String) {
        #expect(InlineArithmetic.result(before: text) == answer)
    }

    @Test(arguments: [
        "12*4",       // no equals sign yet
        "12*4= ",     // something after it
        "5=",         // no operator
        "x=3+4=",     // an equation, not a sum
        "$12*4=",     // currency is deliberately out
        "abc3+4=",    // glued to a word
        "1,5+1=",     // ambiguous decimal comma
        "1,20+1=",    // not a thousands group
        "4/0=",       // nothing to say
        "3+=",        // unfinished
        "(3+4=",      // unbalanced
        "=",
        "",
    ])
    func anythingElseIsLeftAlone(text: String) {
        #expect(InlineArithmetic.result(before: text) == nil)
    }

    @Test func nothingIsReadWithoutADocument() {
        #expect(InlineArithmetic.result(before: nil) == nil)
    }

    @Test func aRunawaySumIsNotParsed() {
        let sum = Array(repeating: "1", count: 40).joined(separator: "+") + "="
        #expect(InlineArithmetic.result(before: sum) == nil)
    }

    @Test func theAnswerLeadsAnEmptyStrip() {
        var context = TypingCandidates.Context()
        context.calculation = "48"
        context.predictions = ["a", "b", "c"]
        let strip = TypingCandidates.strip(context)
        #expect(strip.candidates.map(\.kind) == [.calculation, .prediction, .prediction])
        #expect(strip.autocorrection == nil)
        // Never a boundary key's to apply.
        #expect(strip.candidates.allSatisfy { !$0.isEmphasised })
        context.predictionEnabled = false
        #expect(TypingCandidates.strip(context).candidates.map(\.kind) == [.calculation])
    }
}

/// The autocorrect strength picker. Normal must be the rule exactly as it was.
struct AutocorrectStrengthTests {
    private static func context(
        _ composition: String,
        guesses: [String],
        strength: AutocorrectStrength
    ) -> TypingCandidates.Context {
        var context = TypingCandidates.Context()
        context.composition = composition
        context.systemGuesses = guesses
        context.hasCheckerAnswer = true
        context.strength = strength
        return context
    }

    @Test func normalIsTheRuleBeforeTheSetting() {
        #expect(TypingCandidates.Context().strength == .normal)
        #expect(AutocorrectStrength.normal.maximumEdits == 2)
        #expect(AutocorrectStrength.normal.costMargin == 0.7)
        #expect(AutocorrectStrength.normal.minimumLength == 3)
    }

    /// "hend": "bend" is a neighbouring key away and "hand" is not, which
    /// puts them 0.6 apart — not enough for Normal, enough for Aggressive.
    @Test func aggressiveSettlesANarrowerLead() {
        #expect(TypingCandidates.autocorrection(
            Self.context("hend", guesses: ["hand", "bend"], strength: .normal)
        ) == nil)
        #expect(TypingCandidates.autocorrection(
            Self.context("hend", guesses: ["hand", "bend"], strength: .aggressive)
        ) == "bend")
        #expect(TypingCandidates.autocorrection(
            Self.context("hend", guesses: ["hand", "bend"], strength: .mild)
        ) == nil)
    }

    @Test func mildLeavesTwoEditsAlone() {
        let guesses = ["puzzle"]
        #expect(TypingCandidates.autocorrection(Self.context("xyzzle", guesses: guesses, strength: .normal)) == "puzzle")
        #expect(TypingCandidates.autocorrection(Self.context("xyzzle", guesses: guesses, strength: .aggressive)) == "puzzle")
        #expect(TypingCandidates.autocorrection(Self.context("xyzzle", guesses: guesses, strength: .mild)) == nil)
    }

    @Test func mildLeavesThreeLetterWordsToTheTable() {
        #expect(TypingCandidates.autocorrection(Self.context("teh", guesses: ["the"], strength: .normal)) == "the")
        #expect(TypingCandidates.autocorrection(Self.context("teh", guesses: ["the"], strength: .mild)) == nil)
        // A slip in a longer word is still fixed.
        #expect(TypingCandidates.autocorrection(Self.context("becuase", guesses: ["because"], strength: .mild)) == "because")
        // And the curated table does not depend on strength.
        #expect(TypingCandidates.autocorrection(Self.context("i", guesses: [], strength: .mild)) == "I")
    }

    /// A text replacement is an instruction, at every strength.
    @Test func instructionsApplyAtEveryStrength() {
        for strength in AutocorrectStrength.allCases {
            var context = Self.context("omw", guesses: [], strength: strength)
            context.lexiconExpansion = "On my way!"
            #expect(TypingCandidates.autocorrection(context) == "On my way!")
        }
    }
}

/// Words the user held on the strip: never offered, never corrected to.
struct BlockedWordTests {
    @Test func aBlockedWordLeavesTheStrip() {
        var context = TypingCandidates.Context()
        context.composition = "th"
        context.listCompletions = ["the", "that", "this"]
        context.blockedWords = ["that"]
        let words = TypingCandidates.strip(context).candidates.map(\.text)
        #expect(words == ["the", "this"])
    }

    @Test func aBlockedPredictionIsNotOffered() {
        var context = TypingCandidates.Context()
        context.predictions = ["you", "the", "a"]
        context.blockedWords = ["the"]
        #expect(TypingCandidates.strip(context).candidates.map(\.text) == ["you", "a"])
    }

    /// The next reading has to win on its own margin, not inherit the
    /// blocked word's.
    @Test func autocorrectNeverLandsOnABlockedWord() {
        var context = TypingCandidates.Context()
        context.composition = "teh"
        context.hasCheckerAnswer = true
        context.systemGuesses = ["the", "tech"]
        #expect(TypingCandidates.autocorrection(context) == "the")
        context.blockedWords = ["the"]
        #expect(TypingCandidates.autocorrection(context) != "the")

        context.systemGuesses = []
        context.lexiconExpansion = "On my way!"
        context.composition = "omw"
        context.blockedWords = ["on my way!"]
        #expect(TypingCandidates.autocorrection(context) == nil)
    }

    @Test func onlyWordsTheKeyboardChoseCanBeBlocked() {
        for kind in [TypingCandidate.Kind.completion, .prediction, .swipeAlternate] {
            #expect(TypingCandidate(text: "x", kind: kind).isBlockable)
        }
        // A correction chip is the everyday word it corrects to; holding it
        // must not block "the" everywhere.
        for kind in [TypingCandidate.Kind.correction, .literal, .revert, .emoji, .writingFix,
                     .writingReview, .paste, .nextKeyboard, .calculation] {
            #expect(!TypingCandidate(text: "x", kind: kind).isBlockable)
        }
    }

    /// One slip of a held thumb must not stop the keyboard fixing "i".
    @Test func theCuratedShortWordsCannotBeBlocked() {
        for word in ["I", "I'm", "don't", "can't", "i'm"] {
            #expect(!TypingCandidate(text: word, kind: .prediction).isBlockable, "\(word)")
            #expect(!TypingCandidate(text: word, kind: .completion).isBlockable, "\(word)")
        }
        #expect(TypingCandidate(text: "Ivy", kind: .prediction).isBlockable)
    }

    /// Undo straight after a block puts back the word, its learned entry and
    /// the fix that led to it.
    @Test func undoingABlockRestoresWhatItTookAway() {
        var words = LearnedWords()
        words.learn("Kanishk")
        words.noteFix(typo: "kanihsk", fix: "Kanishk")
        words.noteFix(typo: "kanihsk", fix: "Kanishk")
        let before = words
        let blocking = words.blocking("kanishk")
        words.block("kanishk")
        #expect(words.isBlocked("Kanishk"))
        words.undo(blocking)
        #expect(!words.isBlocked("Kanishk"))
        #expect(words.contains("Kanishk"))
        #expect(words.learnedFix(for: "kanihsk") == "Kanishk")
        #expect(words.blockedCount == before.blockedCount)

        // A word that was already blocked stays blocked.
        words.block("gonna")
        let again = words.blocking("gonna")
        words.block("gonna")
        words.undo(again)
        #expect(words.isBlocked("gonna"))
    }

    @Test func blockingForgetsTheLearnedWordAndItsFix() {
        var words = LearnedWords()
        words.learn("Kanishk")
        words.noteFix(typo: "kanihsk", fix: "Kanishk")
        words.noteFix(typo: "kanihsk", fix: "Kanishk")
        #expect(words.learnedFix(for: "kanihsk") == "Kanishk")
        words.block("kanishk")
        #expect(words.isBlocked("Kanishk"))
        #expect(!words.contains("Kanishk"))
        #expect(words.learnedFix(for: "kanihsk") == nil)
        #expect(words.blockedCount == 1)
        #expect(words.blockedWords == ["kanishk"])
    }

    /// Asserting a word is the newer instruction.
    @Test func learningAWordUnblocksIt() {
        var words = LearnedWords()
        words.block("gonna")
        words.learn("gonna")
        #expect(!words.isBlocked("gonna"))
    }

    /// "Reset learned words" promises nothing else is affected.
    @Test func resetsAreSeparate() {
        var words = LearnedWords()
        words.learn("vocaphone")
        words.block("gonna")
        words.removeAll()
        #expect(words.count == 0)
        #expect(words.isBlocked("gonna"))
        words.learn("vocaphone")
        words.removeAllBlocked()
        #expect(words.blockedCount == 0)
        #expect(words.contains("vocaphone"))
    }

    @Test func theOldestBlocksGoFirstPastCapacity() {
        var words = LearnedWords()
        let start = Date(timeIntervalSince1970: 0)
        for index in 0...LearnedWords.blockedCapacity {
            words.block("word\(index)", now: start.addingTimeInterval(Double(index)))
        }
        #expect(words.blockedCount == LearnedWords.blockedCapacity)
        #expect(!words.isBlocked("word0"))
        #expect(words.isBlocked("word\(LearnedWords.blockedCapacity)"))
    }

    /// A file written before blocking existed still reads.
    @Test func anOlderFileDecodes() throws {
        let old = #"{"entries":{"hi":{"word":"hi","count":3,"lastUsedAt":0}}}"#
        let words = try JSONDecoder().decode(LearnedWords.self, from: Data(old.utf8))
        #expect(words.count == 1)
        #expect(words.blockedCount == 0)
    }

    @Test func blockedWordsSurviveTheStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LearnedWordStore(containerURL: directory)
        store.update { $0.block("gonna") }
        store.update { $0.learn("vocaphone") }
        store.flush(timeout: .seconds(2))
        store.removeAll()
        let reopened = LearnedWordStore(containerURL: directory)
        #expect(reopened.snapshot().isBlocked("gonna"))
        #expect(reopened.snapshot().count == 0)
        reopened.removeAllBlocked()
        #expect(LearnedWordStore(containerURL: directory).snapshot().blockedCount == 0)
    }

    /// Settings loads its store when it opens. A reset there must start from
    /// the file, not from that copy, or it undoes what the keyboard did since.
    @Test func aResetStartsFromTheFileNotAStaleCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = LearnedWordStore(containerURL: directory)
        let keyboard = LearnedWordStore(containerURL: directory)
        keyboard.update { $0.block("gonna") }
        keyboard.update { $0.learn("vocaphone") }
        keyboard.flush(timeout: .seconds(2))
        // Reset learned words keeps a block made after Settings opened.
        settings.removeAll()
        let afterReset = LearnedWordStore(containerURL: directory).snapshot()
        #expect(afterReset.isBlocked("gonna"))
        #expect(afterReset.count == 0)

        keyboard.update { $0.learn("kanishk") }
        keyboard.flush(timeout: .seconds(2))
        // Unblocking keeps a word learned after Settings opened.
        settings.removeAllBlocked()
        let afterUnblock = LearnedWordStore(containerURL: directory).snapshot()
        #expect(afterUnblock.blockedCount == 0)
        #expect(afterUnblock.contains("kanishk"))
    }

    /// A keyboard that stays alive picks up Settings' Unblock on its next
    /// appearance, and does not write its old copy back over it.
    @Test func aReloadedKeyboardDoesNotUndoAnUnblock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyboard = LearnedWordStore(containerURL: directory)
        keyboard.update { $0.block("gonna") }
        keyboard.flush(timeout: .seconds(2))
        LearnedWordStore(containerURL: directory).removeAllBlocked()

        let reloaded: LearnedWords = await withCheckedContinuation { continuation in
            keyboard.reload { continuation.resume(returning: $0) }
        }
        #expect(reloaded.blockedCount == 0)
        keyboard.update { $0.learn("vocaphone") }
        keyboard.flush(timeout: .seconds(2))
        let onDisk = LearnedWordStore(containerURL: directory).snapshot()
        #expect(onDisk.blockedCount == 0)
        #expect(onDisk.contains("vocaphone"))
    }
}

/// The engine end of all of the above, with the preferences they read pinned.
@MainActor
@Suite(.serialized)
struct TypingIntelligenceEngineTests {
    private func withEngine(_ body: (TypingEngine) -> Void) {
        let suggestions = KeyboardPreferences.typingSuggestionsEnabled
        let autocorrect = KeyboardPreferences.autocorrectEnabled
        let prediction = KeyboardPreferences.nextWordPredictionEnabled
        let strength = KeyboardPreferences.autocorrectStrength
        defer {
            KeyboardPreferences.typingSuggestionsEnabled = suggestions
            KeyboardPreferences.autocorrectEnabled = autocorrect
            KeyboardPreferences.nextWordPredictionEnabled = prediction
            KeyboardPreferences.autocorrectStrength = strength
        }
        KeyboardPreferences.typingSuggestionsEnabled = true
        KeyboardPreferences.autocorrectEnabled = true
        KeyboardPreferences.nextWordPredictionEnabled = true
        KeyboardPreferences.autocorrectStrength = .normal
        let engine = TypingEngine(learned: LearnedWordStore(containerURL: nil), wordList: .empty)
        defer { engine.suspend() }
        body(engine)
    }

    private static let noAutocorrection = TypingFieldPolicy.resolve(
        isSecureTextEntry: false, contentType: nil, keyboardType: .default, autocorrectionType: .no
    )

    @Test func aFieldWithoutAutocorrectionGetsNoStrip() {
        withEngine { engine in
            engine.installLexicon([.init(userInput: "omw", documentText: "On my way!")])
            engine.documentChanged(policy: Self.noAutocorrection)
            engine.insert("omw", document: DocumentSnapshot(before: "omw"))
            #expect(engine.strip.isEmpty)
            #expect(engine.strip.autocorrection == nil)
            // A swipe still types, but offers nothing to swap it for.
            engine.noteSwipeWord("sad", alternates: ["said", "sat"])
            #expect(engine.strip.isEmpty)
            // And back in an ordinary field the expansion is offered again.
            engine.documentChanged(policy: .allowed)
            engine.insert("omw", document: DocumentSnapshot(before: "omw"))
            #expect(engine.strip.autocorrection == "On my way!")
        }
    }

    @Test func aSnippetBehavesLikeATextReplacement() {
        withEngine { engine in
            engine.installSnippets([
                Snippet(trigger: "sig", expansion: "Best wishes, Sam"),
                // Can never be typed as one word, so it is not installed.
                Snippet(trigger: "my email", expansion: "sam@example.com"),
            ])
            engine.insert("si", document: DocumentSnapshot(before: "si"))
            #expect(engine.strip.autocorrection == nil)
            #expect(engine.strip.candidates.first?.text == "Best wishes, Sam")

            engine.insert("g", document: DocumentSnapshot(before: "sig"))
            #expect(engine.strip.autocorrection == "Best wishes, Sam")
            #expect(engine.strip.candidates.first == TypingCandidate(text: "sig", kind: .literal))
            #expect(engine.strip.candidates.contains {
                $0.text == "Best wishes, Sam" && $0.isEmphasised
            })

            engine.resetComposition(document: DocumentSnapshot(before: "sig "))
            engine.insert("my", document: DocumentSnapshot(before: "sig my"))
            #expect(!engine.strip.candidates.contains { $0.text == "sam@example.com" })
        }
    }

    @Test func aSnippetOutranksATextReplacementWithTheSameTrigger() {
        withEngine { engine in
            engine.installLexicon([.init(userInput: "sig", documentText: "Sent from my iPhone")])
            engine.installSnippets([Snippet(trigger: "SIG", expansion: "Best wishes, Sam")])
            engine.insert("sig", document: DocumentSnapshot(before: "sig"))
            #expect(engine.strip.autocorrection == "Best wishes, Sam")
        }
    }

    @Test func blockingTakesAWordOffTheStripAtOnce() {
        withEngine { engine in
            engine.installLexicon([.init(userInput: "omw", documentText: "On my way!")])
            engine.insert("omw", document: DocumentSnapshot(before: "omw"))
            #expect(engine.strip.autocorrection == "On my way!")
            engine.block("On my way!")
            #expect(engine.strip.autocorrection == nil)
            #expect(!engine.strip.candidates.contains { $0.text == "On my way!" })
            #expect(engine.blockedWordCount == 1)
        }
    }

    @Test func aBlockedWordIsNotASwipesAnswer() {
        withEngine { engine in
            engine.block("sad")
            let screened = engine.screenedSwipe("sad", alternates: ["said", "sat"])
            #expect(screened?.0 == "said")
            #expect(screened?.1 == ["sat"])
        }
    }

    /// The swipe's row is the strip until the next key, so a word held there
    /// leaves it at once.
    @Test func blockingASwipeAlternateTakesItOffTheRow() {
        withEngine { engine in
            engine.noteSwipeWord("sad", alternates: ["said", "sat"])
            #expect(engine.strip.candidates.map(\.text) == ["said", "sat"])
            engine.block("said")
            #expect(engine.strip.candidates.map(\.text) == ["sat"])
        }
    }

    @Test func aSumBeforeTheCursorOffersItsAnswer() {
        withEngine { engine in
            engine.insert("=", document: DocumentSnapshot(before: "12*4="))
            #expect(engine.strip.candidates.first == TypingCandidate(text: "48", kind: .calculation))
            engine.insert(" ", document: DocumentSnapshot(before: "12*4= "))
            #expect(!engine.strip.candidates.contains { $0.kind == .calculation })
        }
    }

    @Test func strengthIsReadFromSettings() {
        withEngine { _ in
            KeyboardPreferences.autocorrectStrength = .mild
            #expect(KeyboardPreferences.autocorrectStrength == .mild)
            KeyboardPreferences.defaults?.set("nonsense", forKey: KeyboardPreferences.autocorrectStrengthKey)
            #expect(KeyboardPreferences.autocorrectStrength == .normal)
        }
    }
}
