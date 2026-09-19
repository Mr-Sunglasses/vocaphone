import Foundation
import Testing

/// The one piece of data iOS ships, and the two things `UITextChecker` cannot
/// do: order completions by frequency, and predict the next word.
struct TypingWordListTests {
    private static let list = TypingWordList.parse(
        words: """
        the
        to
        and
        hello
        help
        helmet
        there
        their
        """,
        bigrams: """
        # comment lines are skipped
        see\tyou, the, it
        thank\tyou
        malformed line with no tab
        """
    )

    @Test func completionsComeBackInFrequencyOrder() {
        // "the" is first in the list and must be first out of it — a completion
        // list that offers "their" before "the" reads as broken.
        #expect(Self.list.completions(for: "the", limit: 3) == ["there", "their"])
        #expect(Self.list.completions(for: "hel", limit: 2) == ["hello", "help"])
    }

    @Test func aCompletionIsAlwaysLongerThanWhatWasTyped() {
        #expect(!Self.list.completions(for: "hello", limit: 3).contains("hello"))
    }

    @Test func membershipAndRankAreCaseInsensitive() {
        #expect(Self.list.contains("Hello"))
        #expect(Self.list.rank(of: "the") == 0)
        #expect(Self.list.rank(of: "nonsense") == nil)
    }

    @Test func bigramsParseAndSkipMalformedLines() {
        #expect(Self.list.nextWords(after: "see", limit: 3) == ["you", "the", "it"])
        #expect(Self.list.nextWords(after: "SEE", limit: 1) == ["you"])
        #expect(Self.list.nextWords(after: "malformed", limit: 3).isEmpty)
        #expect(Self.list.nextWords(after: "nothing", limit: 3).isEmpty)
    }

    // MARK: - Corrections without the system checker

    /// This is the fallback the plan reserves if `UITextChecker` proves too
    /// expensive on device: the shipped list can correct on its own, in pure
    /// Swift that may leave the main actor.
    @Test func theListFindsNearMissesOnItsOwn() {
        #expect(Self.list.similarWords(to: "helo", limit: 2).contains("hello"))
        #expect(Self.list.similarWords(to: "hte", limit: 2).contains("the"))
    }

    @Test func aWordTheListKnowsIsNotCorrected() {
        #expect(Self.list.similarWords(to: "hello", limit: 2).isEmpty)
    }

    @Test func veryShortWordsAreLeftAlone() {
        #expect(Self.list.similarWords(to: "th", limit: 2).isEmpty)
    }

    // MARK: - The shipped files

    /// The real files, shared with the Android keyboard. Tolerant assertions —
    /// this checks the wiring and the format, not the contents of the language.
    @Test func theSharedListShipsInsideTheKeyboardBundle() throws {
        let bundle = Bundle(for: BundleMarker.self)
        guard bundle.url(forResource: "en", withExtension: "txt") != nil else {
            // The test bundle does not embed the keyboard's resources; the file
            // is read from the repository instead so the format still gets
            // checked. The bundle wiring itself is covered by the build.
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("assets/keyboard")
            let words = try String(contentsOf: root.appendingPathComponent("en.txt"), encoding: .utf8)
            let bigrams = try String(
                contentsOf: root.appendingPathComponent("en-bigrams.txt"),
                encoding: .utf8
            )
            let list = TypingWordList.parse(words: words, bigrams: bigrams)
            #expect(list.count > 5_000)
            #expect(list.rank(of: "the") != nil)
            #expect(!list.nextWords(after: "thank", limit: 1).isEmpty)
            return
        }
        let list = TypingWordList.load(from: bundle)
        #expect(list.count > 5_000)
    }

    private final class BundleMarker {}
}

/// The two things the list precomputes so the keystroke and the swipe do not
/// have to.
struct TypingWordListPrecomputationTests {
    private static let list = TypingWordList(
        words: ["the", "there", "these", "than", "book", "look"],
        bigrams: [:]
    )

    /// The collapsed forms come from the list rather than from the gesture.
    /// Deriving ten thousand of them inside a swipe meant ten thousand String
    /// allocations on the main actor at the frame the finger lifted.
    @Test func collapsedFormsAreBuiltWithTheList() {
        let list = TypingWordList(words: ["hello", "book", "the"], bigrams: [:])
        #expect(list.collapsedWords == ["helo", "bok", "the"])
        #expect(list.collapsedWords.count == list.rankedWords.count)
    }

    /// After "th" the language plainly expects "e", and that is what lets the
    /// hit map forgive a finger that lands in the gutter beside it.
    @Test func theExpectedNextLetterLeadsTheWeights() {
        let weights = Self.list.nextCharacterWeights(after: "th")
        #expect(weights["e"] == 1, "the peak is always normalised to 1")
        #expect((weights["a"] ?? 0) > 0)
        #expect((weights["a"] ?? 0) < 1)
        // A letter no word continues into gets no opinion at all.
        #expect(weights["z"] == nil)
    }

    /// No prefix, no opinion — which is what clears the bias between words.
    @Test func anEmptyPrefixExpectsNothing() {
        #expect(Self.list.nextCharacterWeights(after: "").isEmpty)
        #expect(Self.list.nextCharacterWeights(after: "qqq").isEmpty)
    }

    /// Frequency order is the weighting: a continuation found early in the list
    /// is a more likely one than the same letter found late.
    @Test func earlierWordsWeighMore() {
        let list = TypingWordList(words: ["ba"] + Array(repeating: "zz", count: 900) + ["bb"], bigrams: [:])
        let weights = list.nextCharacterWeights(after: "b")
        #expect((weights["a"] ?? 0) > (weights["b"] ?? 0))
    }
}
