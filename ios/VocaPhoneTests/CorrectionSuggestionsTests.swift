import Foundation
import Testing

/// Suggesting, adding and dismissing learned spellings, and the App Group
/// hand-off from the keyboard. The suggestion cases match
/// `CorrectionSuggestionsTest.kt`.
struct CorrectionSuggestionsTests {
    private let namrata = LearnedCorrection(heard: "Namratha", corrected: "Namrata", heardIsWord: false, namesTerm: true)
    private let main = LearnedCorrection(heard: "mane", corrected: "main", heardIsWord: true, namesTerm: false)
    private let now = Date(timeIntervalSince1970: 1_000)

    private func receive(
        _ found: [LearnedCorrection],
        into suggestions: [CorrectionSuggestion] = [],
        dismissed: [String] = [],
        listed: (String, String) -> Bool = { _, _ in false }
    ) -> CorrectionSuggestions.Received {
        CorrectionSuggestions.receive(found, into: suggestions, dismissed: dismissed, now: now, isListed: listed)
    }

    @Test func aFirstFixIsSuggested() {
        let received = receive([namrata])
        #expect(received.suggestions.map(\.corrected) == ["Namrata"])
        #expect(received.suggestions.first?.occurrences == 1)
        #expect(received.added.isEmpty)
    }

    @Test func theSameNameFixedTwiceIsAdded() {
        let once = receive([namrata]).suggestions
        let twice = receive([namrata], into: once)
        #expect(twice.suggestions.isEmpty)
        #expect(twice.added.map(\.corrected) == ["Namrata"])
        #expect(twice.added.first?.occurrences == 2)
    }

    @Test func aPlainWordFixedTwiceStaysASuggestion() {
        let once = receive([main]).suggestions
        let twice = receive([main], into: once)
        #expect(twice.added.isEmpty)
        #expect(twice.suggestions.first?.occurrences == 2)
    }

    @Test func dismissedAndListedFixesAreSkipped() {
        let key = CorrectionSuggestion.key(heard: "namratha", corrected: "Namrata")
        #expect(receive([namrata], dismissed: [key]).suggestions.isEmpty)
        #expect(receive([namrata], listed: { _, corrected in corrected == "Namrata" }).suggestions.isEmpty)
    }

    @Test func theListIsCappedNewestFirst() {
        let many = (0..<(CorrectionSuggestions.capacity + 5)).map {
            LearnedCorrection(heard: "heard\($0)", corrected: "Written\($0)", heardIsWord: false, namesTerm: false)
        }
        let received = receive(many)
        #expect(received.suggestions.count == CorrectionSuggestions.capacity)
        #expect(received.suggestions.first?.corrected == "Written\(CorrectionSuggestions.capacity + 4)")
    }

    private func learned(_ heard: String, _ corrected: String, heardIsWord: Bool) -> CorrectionSuggestions.Learned {
        let suggestion = CorrectionSuggestion(
            heard: heard, corrected: corrected, occurrences: 1, lastSeen: now,
            heardIsWord: heardIsWord, namesTerm: true
        )
        return CorrectionSuggestions.learn(suggestion, replacements: [])
    }

    @Test func addingWritesAReplacementOnlyWhereItIsSafe() {
        // Different letters: a replacement, and the word.
        let name = learned("Namratha", "Namrata", heardIsWord: false)
        #expect(name.replacements.map(\.heard) == ["Namratha"])
        #expect(name.replacements.map(\.written) == ["Namrata"])
        #expect(name.term == "Namrata")
        // Fixing "cloud" once must not rewrite every cloud.
        #expect(learned("cloud", "Claude", heardIsWord: true).replacements.isEmpty)
        // A casing fix needs no replacement; joined words get one.
        #expect(learned("github", "GitHub", heardIsWord: false).replacements.isEmpty)
        #expect(learned("git hub", "GitHub", heardIsWord: false).replacements.map(\.heard) == ["git hub"])
    }

    @Test func listedMeansACustomWordOrAReplacementFromTheSameHearing() {
        let rows = [WordReplacement(heard: "get hub, git hub", written: "GitHub")]
        #expect(CorrectionSuggestions.isListed(heard: "Git Hub", corrected: "GitHub", replacements: rows, vocabulary: []))
        #expect(CorrectionSuggestions.isListed(heard: "x", corrected: "Namrata", replacements: [], vocabulary: ["Namrata"]))
        #expect(!CorrectionSuggestions.isListed(heard: "gitbub", corrected: "GitHub", replacements: rows, vocabulary: []))
    }

    @Test func anAddedWordJoinsTheCustomWordsWithoutRewritingThem() {
        #expect(CorrectionSuggestions.vocabulary("", adding: "Namrata") == "Namrata")
        #expect(CorrectionSuggestions.vocabulary("Kubernetes, kubectl", adding: "Namrata") == "Kubernetes, kubectl\nNamrata")
        #expect(CorrectionSuggestions.vocabulary("Namrata", adding: "Namrata") == "Namrata")
        // A differently cased copy gives way.
        #expect(CorrectionSuggestions.vocabulary("github, Kubernetes", adding: "GitHub") == "Kubernetes\nGitHub")
    }

    @Test func dismissalsAreKeptNewestLastAndBounded() {
        var dismissed: [String] = []
        for index in 0..<(CorrectionSuggestions.dismissedCapacity + 3) {
            dismissed = CorrectionSuggestions.dismissing("k\(index)", from: dismissed)
        }
        #expect(dismissed.count == CorrectionSuggestions.dismissedCapacity)
        #expect(dismissed.last == "k\(CorrectionSuggestions.dismissedCapacity + 2)")
    }

    @Test func suggestionsSurviveStorage() {
        let suggestions = receive([namrata, main]).suggestions
        let decoded = CorrectionSuggestion.decode(CorrectionSuggestion.encode(suggestions))
        #expect(decoded.map(\.corrected) == ["main", "Namrata"])
        #expect(decoded.first?.heardIsWord == true)
        #expect(CorrectionSuggestion.decode(Data("not json".utf8)).isEmpty)
    }

    // MARK: - The App Group hand-off

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var store: SharedStore { SharedStore(rootOverride: root) }

    private func waiting() -> [String] {
        let directory = root.appendingPathComponent("learned-corrections")
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
    }

    @Test func batchesReachTheAppOnceInOrderAndAreDeleted() throws {
        try store.saveLearnedCorrections(LearnedCorrectionBatch(corrections: [namrata], createdAt: now))
        try store.saveLearnedCorrections(LearnedCorrectionBatch(corrections: [main], createdAt: now.addingTimeInterval(1)))
        #expect(waiting().count == 2)
        let taken = store.takeLearnedCorrections()
        #expect(taken.flatMap(\.corrections) == [namrata, main])
        #expect(waiting().isEmpty)
        #expect(store.takeLearnedCorrections().isEmpty)
    }

    @Test func aBatchHoldsOnlyThePairs() throws {
        try store.saveLearnedCorrections(LearnedCorrectionBatch(corrections: [namrata], createdAt: now))
        let file = root.appendingPathComponent("learned-corrections").appendingPathComponent(try #require(waiting().first))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "id", "corrections", "createdAt"])
        let pair = try #require((object["corrections"] as? [[String: Any]])?.first)
        #expect(Set(pair.keys) == ["heard", "corrected", "heardIsWord", "namesTerm"])
    }

    @Test func waitingBatchesAreBoundedAndAnotherSchemaIsDropped() throws {
        for index in 0..<(LearnedCorrectionBatch.maximumWaiting + 4) {
            let batch = LearnedCorrectionBatch(corrections: [namrata], createdAt: now.addingTimeInterval(Double(index)))
            try store.saveLearnedCorrections(batch)
        }
        #expect(waiting().count == LearnedCorrectionBatch.maximumWaiting)
        let future = #"{"schemaVersion":99,"id":"\#(UUID().uuidString)","corrections":[],"createdAt":"2026-01-01T00:00:00Z"}"#
        try Data(future.utf8).write(to: root.appendingPathComponent("learned-corrections/0-future.json"))
        #expect(store.takeLearnedCorrections().count == LearnedCorrectionBatch.maximumWaiting)
        #expect(waiting().isEmpty)
    }

    @Test func removingClearsEverythingWaiting() throws {
        try store.saveLearnedCorrections(LearnedCorrectionBatch(corrections: [namrata]))
        store.removeLearnedCorrections()
        #expect(waiting().isEmpty)
        #expect(store.takeLearnedCorrections().isEmpty)
    }
}

/// The Suggested screen reloads on `didChange`, so every write has to post it.
@Suite(.serialized)
struct CorrectionLearningPreferencesChangeTests {
    private final class Counter: @unchecked Sendable {
        var posts = 0
    }

    private func posts(during change: () -> Void) -> Int {
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: CorrectionLearningPreferences.didChange, object: nil, queue: nil
        ) { _ in counter.posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        change()
        return counter.posts
    }

    @Test func everyWritePostsAChange() {
        let savedSuggestions = CorrectionLearningPreferences.suggestions
        let savedDismissed = CorrectionLearningPreferences.dismissed
        defer {
            CorrectionLearningPreferences.suggestions = savedSuggestions
            CorrectionLearningPreferences.dismissed = savedDismissed
        }
        #expect(posts { CorrectionLearningPreferences.suggestions = savedSuggestions } == 1)
        #expect(posts { CorrectionLearningPreferences.dismissed = savedDismissed } == 1)
    }
}
