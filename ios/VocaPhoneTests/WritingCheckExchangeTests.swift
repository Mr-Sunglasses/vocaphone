import Foundation
import Testing

/// Writing check in the iOS keyboard, over a real (temporary) shared
/// container: the keyboard's `WritingCheckClient` running the rules and asking
/// for the model, the app's `TypedGrammarResponder` answering. Darwin pings
/// are skipped for a store with a root override, so each test calls the
/// other side by hand. "She go home." stands for a slip only the model
/// catches; the rules alone do not.
@MainActor
struct WritingCheckExchangeTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var store: SharedStore { SharedStore(rootOverride: root) }
    private static let checker = WritingCheck(rules: WritingCheckTests.rules)

    private func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
    }

    private func responder(
        enabled: Bool = true,
        correct: @escaping TypedGrammarResponder.Correct = { text, _, _ in
            text.replacingOccurrences(of: "She go ", with: "She goes ")
        }
    ) -> TypedGrammarResponder {
        TypedGrammarResponder(
            store: store,
            isEnabled: { enabled },
            correct: correct,
            pollInterval: .milliseconds(5),
            loadWait: .milliseconds(50)
        )
    }

    private func client(
        appRunning: Bool = true,
        modelReady: Bool = true,
        now: @escaping () -> Date = { Date() }
    ) -> WritingCheckClient {
        WritingCheckClient(
            store: store,
            isAppRunning: { appRunning },
            modelReady: { modelReady },
            checker: { Self.checker },
            pause: .milliseconds(10),
            now: now,
            observe: { _ in nil }
        )
    }

    private func type(_ client: WritingCheckClient, _ text: String) async throws {
        client.textChanged(before: text, after: "", enabled: true) { WritingCheckClient.Options() }
        await client.settle()
    }

    /// The app's answer read, and the report rebuilt from it.
    private func collect(_ client: WritingCheckClient) async {
        client.collect()
        await client.settle()
    }

    private func labels(_ client: WritingCheckClient) -> [String] {
        client.report?.suggestions.map(\.label) ?? []
    }

    @Test func theButtonChecksWithoutCheckWhileTyping() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        let text = "what is you doing"
        client.checkNow(WritingCheckClient.Field(text: text, cursor: text.utf16.count), options: .init())
        await client.settle()
        #expect(labels(client).contains("is → are"))
        // Typing on with "Check while typing" off moves the report along and
        // checks nothing new until the next tap.
        let more = "what is you doing. They was here"
        client.textChanged(before: more, after: "", enabled: true, autoCheck: false) { WritingCheckClient.Options() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(labels(client) == ["is → are"])
        #expect(client.report?.field.text == more)
        client.checkNow(options: .init())
        await client.settle()
        #expect(labels(client).contains("was → were"))
    }

    @Test func theButtonChecksTheFieldAsItReadsAfterItsPause() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        var text = "I could of told you. "
        var finished = 0
        client.checkAfterPause(
            .milliseconds(30),
            read: { WritingCheckClient.Field(text: text, cursor: text.utf16.count) },
            options: { .init() },
            finished: { finished += 1 }
        )
        // Edited during the pause, with "Check while typing" off.
        text = "I could have told you. "
        client.textChanged(before: text, after: "", enabled: true, autoCheck: false) { WritingCheckClient.Options() }
        await client.settle()
        #expect(client.report?.field.text == text)
        #expect(client.report?.all.contains { $0.shownOriginal == "of" } == false)
        #expect(finished == 1)
    }

    @Test func aClosedPanelDropsTheButtonCheck() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        let text = "I could of told you. "
        var reads = 0
        var finished = 0
        client.checkAfterPause(
            .milliseconds(30),
            read: {
                reads += 1
                return WritingCheckClient.Field(text: text, cursor: text.utf16.count)
            },
            options: { .init() },
            finished: { finished += 1 }
        )
        client.cancelButtonCheck()
        await client.settle()
        #expect(reads == 0)
        #expect(client.report == nil)
        #expect(finished == 1)
        // A field change (or a hidden keyboard) in the pause drops it too.
        client.checkAfterPause(
            .milliseconds(30),
            read: { WritingCheckClient.Field(text: text, cursor: text.utf16.count) },
            options: { .init() }
        )
        client.reset()
        await client.settle()
        #expect(client.report == nil)
        // And a field that cannot be read when the pause ends checks nothing.
        client.checkAfterPause(.milliseconds(10), read: { nil }, options: { .init() })
        await client.settle()
        #expect(client.report == nil)
        #expect(!client.isChecking)
    }

    @Test func adviceIsNotStruckThrough() {
        func make(_ original: String, _ replacement: String?) -> WritingSuggestion {
            let end = (original as NSString).length
            return WritingSuggestion(
                start: 0, end: end, original: original, replacement: replacement,
                markStart: 0, markEnd: end, kind: "passive", category: .clarity,
                title: "Passive voice", message: "", mechanical: false, source: .rule, rule: nil
            )
        }
        #expect(!WritingPanelView.strikesOriginal(make("was written by", nil)))
        #expect(WritingPanelView.strikesOriginal(make("teh", "the")))
        #expect(WritingPanelView.strikesOriginal(make(" very", "")))
        #expect(!WritingPanelView.strikesOriginal(make("", ",")))
    }

    @Test func theButtonDoesNotBlinkWhenIOSDoesNotAnswer() {
        let words = DocumentSnapshot(before: "what is you", after: "")
        let empty = DocumentSnapshot(before: "", after: "")
        let decide = WritingButtonVisibility.decide
        #expect(decide(words, true, false, false) == .show)
        // An unanswered read leaves it as it is; it is not an empty field.
        #expect(decide(.unknown, true, false, true) == .keep)
        #expect(decide(.unknown, true, false, false) == .keep)
        // Wordless hides only after a second look, except in a new field.
        #expect(decide(empty, true, false, true) == .hideAfterPause)
        #expect(decide(empty, true, true, true) == .hide)
        #expect(decide(.unknown, true, true, true) == .hide)
        #expect(decide(DocumentSnapshot(before: "123 ", after: nil), true, false, false) == .keep)
        #expect(decide(words, false, false, true) == .hide)
    }

    @Test func theCardShowsTheChangeInItsSentence() {
        let text = "Hi there. what is you doing now? Bye."
        let report = Self.checker.check(text, model: nil, options: .init(typed: true))
        let s = try! #require(report.suggestions.first { $0.kind == "agreement" })
        let context = WritingPanelView.context(of: s, in: text)
        #expect(context.before + s.shownOriginal + context.after == "what is you doing now?")
        let long = String(repeating: "word ", count: 30) + "they is here"
        let t = Self.checker.check(long, model: nil, options: .init(typed: true))
        let u = try! #require(t.suggestions.first { $0.kind == "agreement" })
        #expect(WritingPanelView.context(of: u, in: long).before.hasPrefix("…"))
    }

    @Test func theQuestionIsDeletedAsItIsRead() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["She go home."], keep: []))
        #expect(files() == ["typed-grammar-request.json"])
        #expect(store.takeTypedGrammarRequest()?.sentences == ["She go home."])
        #expect(files().isEmpty)
        #expect(store.takeTypedGrammarRequest() == nil)
    }

    @Test func aClaimLeftMidReadIsCleared() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("typed-grammar-request.\(UUID().uuidString).taking"))
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["She go home."], keep: []))
        store.clearTypedGrammarExchange()
        #expect(files().isEmpty)
    }

    @Test func theAppAnswersEachSentence() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let request = TypedGrammarRequest(sentences: ["She go home.", "Fine."], keep: [])
        try store.saveTypedGrammarRequest(request)
        responder().answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer() == TypedGrammarAnswer(id: request.id, corrected: ["She goes home.", "Fine."]))
        #expect(files().isEmpty)
    }

    @Test func theAppPassesTheKeptWordsToTheModel() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Box<Set<String>>([])
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["Ask Kubo."], keep: ["kubo"]))
        responder(correct: { text, keep, _ in
            seen.value = keep
            return text
        }).answerPendingRequest()
        #expect(seen.value == ["kubo"])
    }

    @Test func aStaleQuestionIsDroppedUnanswered() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-TypedGrammarRequest.maximumAge - 1)
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["She go home."], keep: [], createdAt: old))
        responder().answerPendingRequest()
        #expect(files().isEmpty)
    }

    @Test func turnedOffInTheAppAnswersWithNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let request = TypedGrammarRequest(sentences: ["She go home.", "Fine."], keep: [])
        try store.saveTypedGrammarRequest(request)
        responder(enabled: false).answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer() == TypedGrammarAnswer(id: request.id, corrected: [nil, nil]))
    }

    @Test func aModelStillLoadingIsWaitedFor() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Box(0)
        let request = TypedGrammarRequest(sentences: ["She go home."], keep: [])
        try store.saveTypedGrammarRequest(request)
        responder(correct: { text, _, _ in
            calls.value += 1
            return calls.value < 3 ? nil : text.replacingOccurrences(of: "She go ", with: "She goes ")
        }).answerPendingRequest()
        #expect(store.takeTypedGrammarAnswer()?.corrected == ["She goes home."])
    }

    @Test func theRulesAnswerWithoutTheApp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        try await type(client, "She go home. I could of told you. ")
        #expect(labels(client) == ["of → have"])
        #expect(files().isEmpty)
    }

    @Test func sentencesTheModelHasNotSeenGoToTheApp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        try await type(client, "She go home. I could of told you. ")
        #expect(labels(client) == ["of → have"])
        #expect(client.report?.modelPending == true)
        responder().answerPendingRequest()
        await collect(client)
        #expect(labels(client) == ["go → goes", "of → have"])
        #expect(files().isEmpty)
    }

    @Test func theAppPassesTheTierToTheModel() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tiers = Box<[Bool]>([])
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["She go home."], keep: [], thorough: true))
        responder(correct: { text, _, thorough in
            tiers.value.append(thorough)
            return text
        }).answerPendingRequest()
        try store.saveTypedGrammarRequest(TypedGrammarRequest(sentences: ["She go home."], keep: []))
        responder(correct: { text, _, thorough in
            tiers.value.append(thorough)
            return text
        }).answerPendingRequest()
        #expect(tiers.value == [true, false])
    }

    @Test func theButtonAsksForTheThoroughTierAndAPauseAfterItToo() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        let tiers = Box<[Bool]>([])
        let answering = responder(correct: { text, _, thorough in
            tiers.value.append(thorough)
            return text
        })
        try await type(client, "She go home. ")
        answering.answerPendingRequest()
        await collect(client)
        let text = "She go home. "
        client.checkAfterPause(
            .milliseconds(1),
            read: { WritingCheckClient.Field(text: text, cursor: text.utf16.count) },
            options: { .init() }
        )
        await client.settle()
        answering.answerPendingRequest()
        await collect(client)
        // The thorough tier keeps its own answers: the button asked again,
        // and the pause after it asks only the new sentence, thoroughly.
        try await type(client, "She go home. They are fine. ")
        answering.answerPendingRequest()
        await collect(client)
        #expect(tiers.value == [false, true, true])
    }

    @Test func answeredSentencesAreNotAskedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        try await type(client, "She go home. ")
        responder().answerPendingRequest()
        await collect(client)
        try await type(client, "She go home. They are fine. ")
        #expect(store.takeTypedGrammarRequest()?.sentences == ["They are fine."])
    }

    @Test func anExpiredQuestionIsAskedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Box(Date())
        let client = client(now: { clock.value })
        try await type(client, "She go home. ")
        // The app never answered, and the question went unread.
        store.clearTypedGrammarExchange()
        clock.value = clock.value.addingTimeInterval(TypedGrammarRequest.maximumAge + 1)
        try await type(client, "She go home. ")
        #expect(store.takeTypedGrammarRequest()?.sentences == ["She go home."])
    }

    @Test func anEmptyAnswerWaitsForThePauseAndIsNotAskedForever() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        try await type(client, "She go home. ")
        // A model that fails to load answers with nothing.
        responder(enabled: false).answerPendingRequest()
        await collect(client)
        #expect(labels(client).isEmpty)
        #expect(files().isEmpty)
        // The next pause asks once more, and then the rules are left to it.
        try await type(client, "She go home. ")
        responder(enabled: false).answerPendingRequest()
        await collect(client)
        try await type(client, "She go home. ")
        #expect(files().isEmpty)
    }

    @Test func aStaleCheckIsNotPublished() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        client.checkNow(WritingCheckClient.Field(text: "I could of told you. ", cursor: 21), options: .init())
        client.reset()
        await client.settle()
        #expect(client.report == nil)
        #expect(!client.isChecking)
    }

    @Test func aDismissedKeyStaysAwayWithoutItsSuggestion() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        try await type(client, "I could of told you. ")
        let key = try #require(client.report?.suggestions.first).key
        client.applied(try #require(client.report?.suggestions.first))
        #expect(labels(client).isEmpty)
        // Undo: the words are back, and the fix is not offered again.
        client.dismiss(key: key)
        try await type(client, "I could of told you. ")
        #expect(labels(client).isEmpty)
    }

    @Test func fixesBeyondTheWindowCannotBeAccepted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        let text = "I could of told you. Sure. They could of known."
        let cursor = ("I could of told you. Sure. " as NSString).length
        client.checkNow(
            WritingCheckClient.Field(text: text, cursor: cursor, reach: (cursor - 6)..<text.utf16.count),
            options: .init()
        )
        await client.settle()
        let report = try #require(client.report)
        #expect(report.suggestions.count == 2)
        #expect(report.suggestions.filter(report.canApply).map(\.start) == [cursor + 11])
        #expect(report.chips.map(\.start) == [cursor + 11])
    }

    @Test func aWindowOntoTheWholeMessageKeepsItsReport() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        let before = "I could of told you. Sure. "
        let after = "They could of known."
        let cursor = (before as NSString).length
        client.checkNow(WritingCheckClient.Field(text: before + after, cursor: cursor, reach: 0..<cursor), options: .init())
        await client.settle()
        #expect(client.report?.count == 2)
        client.textChanged(before: "Sure. ", after: "They could", enabled: true) { WritingCheckClient.Options() }
        await client.settle()
        let report = try #require(client.report)
        #expect(report.count == 2)
        #expect(report.field.reach == (cursor - 6)..<(cursor + 10))
    }

    @Test func undoFindsTheFixWhereItWasMade() throws {
        let text = "thier car is their responsibility "
        let field = WritingCheckClient.Field(text: text, cursor: (text as NSString).length)
        let fix = try #require(WritingAutoFix(suggestion(text, "thier", "their", at: 0), in: field))
        let fixed = "their car is their responsibility "
        #expect(fix.isCurrent(before: fixed))
        // Back from the cursor to the end of the first "their", not the second.
        #expect(fix.distance == ((" car is their responsibility ") as NSString).length)
        #expect(!fix.isCurrent(before: fixed + "x"))
        #expect(!fix.isCurrent(before: "their car is their"))
        #expect(!fix.isCurrent(before: nil))
    }

    private func suggestion(_ text: String, _ original: String, _ replacement: String, at start: Int) -> WritingSuggestion {
        let end = start + (original as NSString).length
        return WritingSuggestion(
            start: start, end: end, original: original, replacement: replacement,
            markStart: start, markEnd: end, kind: "spelling", category: .correctness,
            title: "Spelling", message: "", mechanical: true, source: .rule, rule: nil
        )
    }

    @Test func aDismissedSuggestionStaysAway() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        try await type(client, "I could of told you. ")
        client.dismiss(try #require(client.report?.suggestions.first))
        try await type(client, "I could of told you. Sure. ")
        #expect(labels(client).isEmpty)
    }

    @Test func applyingMovesTheOthers() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        try await type(client, "I definately could of told you. ")
        client.applied(try #require(client.report?.suggestions.first))
        let report = try #require(client.report)
        #expect(report.field.text == "I definitely could of told you. ")
        let rest = try #require(report.suggestions.first)
        #expect(report.field.text.utf16Slice(rest.start, rest.end) == "of")
    }

    @Test func resetRemovesTheQuestionFromTheAppGroup() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client()
        try await type(client, "She go home. ")
        #expect(files() == ["typed-grammar-request.json"])
        client.reset()
        #expect(files().isEmpty)
        #expect(client.report == nil)
    }

    @Test func theWritingDraftIsTakenOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveWritingDraft("She go home.")
        #expect(store.takeWritingDraft() == "She go home.")
        #expect(store.takeWritingDraft() == nil)
        try store.saveWritingDraft("Old.")
        #expect(store.takeWritingDraft(now: Date().addingTimeInterval(WritingDraft.maximumAge + 1)) == nil)
    }

    @Test func aFailedHandOffRemovesTheDraft() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveWritingDraft("She go home.")
        store.removeWritingDraft()
        #expect(files().isEmpty)
        // Nothing there is nothing to do.
        store.removeWritingDraft()
        store.removeExpiredWritingDraft()
    }

    @Test func anExpiredDraftIsSweptAndAFreshOneKept() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveWritingDraft("She go home.")
        store.removeExpiredWritingDraft()
        #expect(files() == ["writing-draft.json"])
        store.removeExpiredWritingDraft(now: Date().addingTimeInterval(WritingDraft.maximumAge + 1))
        #expect(files().isEmpty)
    }

    @Test func aDraftSavedAgainIsNotSweptForTheOldDate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveWritingDraft("Old.")
        let url = root.appendingPathComponent("writing-draft.json")
        let old = Date().addingTimeInterval(-WritingDraft.maximumAge - 1)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        // The file looks old, but the draft in it is not: it stays, and can be taken.
        store.removeExpiredWritingDraft()
        #expect(store.takeWritingDraft() == "Old.")
    }

    // MARK: - Chips and automatic fixes

    @Test func goingBackIntoAFlaggedWordTakesItsChipAway() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        let text = "I definately could of told you. "
        try await type(client, text)
        #expect(labels(client).count == 2)
        // The cursor taps into "definately": the report is moved at once, and
        // neither the chip nor the card for that word stays.
        let inside = ("I defin" as NSString).length
        client.textChanged(
            before: text.utf16Slice(0, inside), after: text.utf16Slice(inside, text.utf16Length), enabled: true
        ) { WritingCheckClient.Options() }
        #expect(client.report?.chips.map(\.original) == ["of"])
        #expect(labels(client) == ["of → have"])
        await client.settle()
        #expect(client.report?.chips.map(\.original) == ["of"])
    }

    @Test func leavingAFlaggedWordBringsItsChipBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        let text = "I definately could of told you. "
        try await type(client, text)
        let inside = ("I defin" as NSString).length
        client.textChanged(
            before: text.utf16Slice(0, inside), after: text.utf16Slice(inside, text.utf16Length), enabled: true
        ) { WritingCheckClient.Options() }
        await client.settle()
        #expect(labels(client) == ["of → have"])
        #expect(client.report?.count == 1)
        // Back to the end: the hidden correction is shown again at once,
        // before any new check, and counted.
        client.textChanged(before: text, after: "", enabled: true) { WritingCheckClient.Options() }
        #expect(client.report?.chips.map(\.original).sorted() == ["definately", "of"])
        #expect(client.report?.count == 2)
        await client.settle()
        #expect(client.report?.chips.map(\.original).sorted() == ["definately", "of"])
        #expect(client.report?.count == 2)
    }

    @Test func aDismissalInsideTheCurrentWordHoldsAfterLeavingIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        let text = "I definately could of told you. "
        try await type(client, text)
        let of = try #require(client.report?.suggestions.first { $0.original == "of" })
        // The cursor goes into "definately", "of" is waved away, and the
        // cursor comes back out: only "definately" returns.
        let inside = ("I defin" as NSString).length
        client.textChanged(
            before: text.utf16Slice(0, inside), after: text.utf16Slice(inside, text.utf16Length), enabled: true
        ) { WritingCheckClient.Options() }
        client.dismiss(of)
        #expect(client.report?.count == 0)
        client.textChanged(before: text, after: "", enabled: true) { WritingCheckClient.Options() }
        #expect(client.report?.suggestions.map(\.original) == ["definately"])
        await client.settle()
        #expect(client.report?.suggestions.map(\.original) == ["definately"])
    }

    @Test func oneAutomaticFixPerUndo() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(appRunning: false)
        var document = "I definately recieve it. "
        try await type(client, document)
        #expect(client.report?.suggestions.count == 2)
        let fixer = WritingAutoFixer()
        var made: [String] = []
        // What the keyboard does on every report change; applying a fix is
        // itself one.
        func autoFix() {
            guard let report = client.report else { return }
            fixer.fix(in: report, apply: { fix in
                guard let edited = WritingCheck.apply(document, fix) else { return false }
                document = edited
                made.append(fix.original)
                client.applied(fix)
                return true
            }, before: { document })
        }
        client.onChange = { autoFix() }
        autoFix()
        // The latest typo only, and Undo takes back exactly that one.
        #expect(made == ["recieve"])
        #expect(document == "I definately receive it. ")
        #expect(fixer.offer?.typed == "recieve")
        // Still one while that Undo is offered, however often the report changes.
        autoFix()
        #expect(made == ["recieve"])
        // Once it is gone, the next one is made with its own Undo.
        fixer.clear()
        autoFix()
        #expect(made == ["recieve", "definately"])
        #expect(fixer.offer?.typed == "definately")
    }
}

/// "Whole message" walking the cursor through a field that hands over eight
/// characters either side of it.
@MainActor
struct WholeMessageWalkTests {
    private static let text = "One two three. Four five six. Seven eight nine."

    @MainActor
    private final class Field {
        var text: String
        var cursor: Int
        var hasSelection = false
        /// Where the window shows the cursor when the field has not caught up
        /// with it yet; nil when it has.
        var shownCursor: Int?
        private(set) var moves: [Int] = []
        let size = 8

        init(_ text: String, cursor: Int) {
            self.text = text
            self.cursor = cursor
        }

        var window: WholeMessageWalk.Window {
            let length = text.utf16Length
            let cursor = shownCursor ?? cursor
            return .init(
                before: text.utf16Slice(max(0, cursor - size), cursor),
                after: text.utf16Slice(cursor, min(length, cursor + size)),
                hasSelection: hasSelection
            )
        }

        func move(_ offset: Int) {
            moves.append(offset)
            cursor = min(max(cursor + offset, 0), text.utf16Length)
        }
    }

    /// A walk over `field`; `onWait` runs at each wait, numbered from 1, and
    /// says whether the walk may go on.
    private func makeWalk(_ field: Field, onWait: @escaping (Int, WholeMessageWalk) -> Bool = { _, _ in true }) -> WholeMessageWalk {
        var waits = 0
        var walk: WholeMessageWalk?
        let made = WholeMessageWalk(
            window: { field.window },
            move: { field.move($0) },
            wait: {
                waits += 1
                return onWait(waits, walk!)
            }
        )
        walk = made
        return made
    }

    @Test func readsPastTheWindowAndPutsTheCursorBack() async throws {
        let field = Field(Self.text, cursor: 20)
        let walk = makeWalk(field)
        let read = try #require(await walk.read())
        #expect(read.text == Self.text)
        #expect(read.cursor == 20)
        #expect(read.reach == 12..<28)
        #expect(field.cursor == 20)
        #expect(!walk.wasInterrupted)
    }

    @Test func aTapElsewhereStopsTheWalkWhereTheUserPutIt() async throws {
        let field = Field(Self.text, cursor: 20)
        let walk = makeWalk(field) { wait, _ in
            if wait == 2 { field.cursor = 40 }
            return true
        }
        #expect(await walk.read() == nil)
        #expect(walk.wasInterrupted)
        #expect(field.cursor == 40)
        #expect(field.moves.count == 2)
        // Closing the panel afterwards leaves it there too.
        walk.restore()
        #expect(field.cursor == 40)
    }

    @Test func anEditStopsTheWalk() async throws {
        let field = Field(Self.text, cursor: 20)
        let walk = makeWalk(field) { wait, _ in
            if wait == 1 { field.text = field.text.replacingOccurrences(of: "Four", with: "4") }
            return true
        }
        #expect(await walk.read() == nil)
        #expect(walk.wasInterrupted)
        #expect(field.moves.count == 1)
    }

    @Test func aSelectionStopsTheWalk() async throws {
        let field = Field(Self.text, cursor: 20)
        let walk = makeWalk(field) { wait, _ in
            if wait == 3 { field.hasSelection = true }
            return true
        }
        #expect(await walk.read() == nil)
        #expect(walk.wasInterrupted)
        #expect(field.moves.count == 3)
    }

    @Test func closingThePanelPutsTheCursorBackBeforeTheKeysReturn() async throws {
        let field = Field(Self.text, cursor: 20)
        // The keys come back mid-walk, past the start on the way forward.
        let walk = makeWalk(field) { wait, walk in
            guard wait == 5 else { return true }
            walk.restore()
            #expect(field.cursor == 20)
            return false
        }
        #expect(await walk.read() == nil)
        #expect(!walk.wasInterrupted)
        #expect(field.cursor == 20)
        // Once stopped, nothing moves it again.
        walk.restore()
        #expect(field.cursor == 20)
    }

    @Test func closingAfterAnOutsideMoveLeavesTheCursorAlone() async throws {
        let field = Field(Self.text, cursor: 20)
        // The user taps elsewhere during a wait, and the panel closes before
        // the walk has looked: the cursor stays where the user put it.
        let walk = makeWalk(field) { wait, walk in
            guard wait == 2 else { return true }
            field.cursor = 40
            walk.restore()
            return false
        }
        #expect(await walk.read() == nil)
        #expect(walk.wasInterrupted)
        #expect(field.cursor == 40)
        #expect(field.moves.count == 2)
    }

    @Test func closingAfterAnOutsideEditLeavesTheCursorAlone() async throws {
        let field = Field(Self.text, cursor: 20)
        let walk = makeWalk(field) { wait, walk in
            guard wait == 1 else { return true }
            field.text = field.text.replacingOccurrences(of: "Four", with: "4")
            walk.restore()
            return false
        }
        #expect(await walk.read() == nil)
        #expect(walk.wasInterrupted)
        #expect(field.cursor == 12)
        #expect(field.moves.count == 1)
    }

    @Test func closingBeforeTheFieldCatchesUpStillPutsTheCursorBack() async throws {
        let field = Field(Self.text, cursor: 20)
        // The panel closes right after the walk's own move, while the window
        // still shows the cursor where it was before it.
        let walk = makeWalk(field) { wait, walk in
            guard wait == 2 else { return true }
            field.shownCursor = field.cursor - field.moves.last!
            walk.restore()
            field.shownCursor = nil
            return false
        }
        #expect(await walk.read() == nil)
        #expect(!walk.wasInterrupted)
        #expect(field.cursor == 20)
        #expect(field.moves.count == 3)
    }

    @Test func aRestoredWalkMakesNoFurtherMoves() async throws {
        let field = Field(Self.text, cursor: 20)
        let walk = makeWalk(field) { wait, walk in
            if wait == 2 { walk.restore() }
            // Even told to go on, it does not.
            return true
        }
        #expect(await walk.read() == nil)
        #expect(field.cursor == 20)
        #expect(field.moves.count == 3)
    }
}

/// A mutable cell a `@Sendable` closure can write to in a test.
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// What the keyboard's Writing check panel says about how the text sounds.
struct WritingPanelModelTests {
    /// "rules 52" in the shared fixtures: three tones and nothing to fix.
    private static let text =
        "I'm sorry for the delay. Thanks so much for your patience, I really appreciate it and hope you have a great weekend!"

    private func report(_ text: String) -> WritingCheckClient.Report {
        let result = WritingCheck(rules: WritingCheckTests.rules).check(text)
        return WritingCheckClient.Report(
            field: .init(text: text, cursor: text.utf16.count),
            all: result.suggestions,
            tones: result.tones,
            modelPending: false
        )
    }

    @Test func aTextWithNothingToFixStillShowsItsTone() throws {
        let model = WritingPanelModel()
        model.report = report(Self.text)
        #expect(model.report?.suggestions.isEmpty == true)
        let tone = try #require(model.emptyStateTone)
        #expect(tone.hasPrefix("Sounds "))
        #expect(tone == model.toneLine)
        #expect(tone.components(separatedBy: " · ").count == 3)
    }

    @Test func theEmptyStateHasNoToneWhileCheckingOrBeforeAReport() {
        let model = WritingPanelModel()
        #expect(model.toneLine == nil)
        #expect(model.emptyStateTone == nil)
        model.report = report(Self.text)
        model.isChecking = true
        #expect(model.emptyStateTone == nil)
        model.isChecking = false
        model.isReadingMessage = true
        #expect(model.emptyStateTone == nil)
    }
}
