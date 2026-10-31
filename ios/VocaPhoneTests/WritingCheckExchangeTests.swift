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
        correct: @escaping TypedGrammarResponder.Correct = { text, _ in
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
        responder(correct: { text, keep in
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
        responder(correct: { text, _ in
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
        private(set) var moves: [Int] = []
        let size = 8

        init(_ text: String, cursor: Int) {
            self.text = text
            self.cursor = cursor
        }

        var window: WholeMessageWalk.Window {
            let length = text.utf16Length
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
