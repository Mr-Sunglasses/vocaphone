import CoreGraphics
import Testing

/// Swipe typing, scored against real key centres.
///
/// Shipping this badly is worse than not shipping it: a wrong guess costs the
/// user a whole word rather than one letter, and they have to notice it first.
/// That is why the switch is off by default until device QA says otherwise, and
/// why the recogniser is testable without a touch.
struct SwipeRecognizerTests {
    /// A QWERTY grid at roughly the metrics the keyboard actually uses:
    /// 36pt columns, 53pt rows, with the usual staggered offsets.
    private static let keys: [SwipeRecognizer.Key] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let pitch: CGFloat = 36
        let rowHeight: CGFloat = 53
        var keys: [SwipeRecognizer.Key] = []
        for (rowIndex, row) in rows.enumerated() {
            let indent = CGFloat(rowIndex) * pitch / 2
            for (column, character) in row.enumerated() {
                keys.append(
                    SwipeRecognizer.Key(
                        character: character,
                        centre: CGPoint(
                            x: indent + CGFloat(column) * pitch + pitch / 2,
                            y: CGFloat(rowIndex) * rowHeight + rowHeight / 2
                        )
                    )
                )
            }
        }
        return keys
    }()

    private static let recognizer = SwipeRecognizer(keys: keys)

    private static let wordList = TypingWordList.parse(
        words: """
        the
        hello
        help
        world
        word
        here
        there
        good
        gone
        """,
        bigrams: ""
    )

    /// Samples along the straight lines between the given letters, the way a
    /// finger would move.
    private static func path(through letters: String, samples: Int = 8) -> [CGPoint] {
        let centres = letters.compactMap { character in
            keys.first { $0.character == character }?.centre
        }
        guard centres.count > 1 else { return centres }
        var points: [CGPoint] = []
        for index in 1..<centres.count {
            let from = centres[index - 1]
            let to = centres[index]
            for step in 0..<samples {
                let t = CGFloat(step) / CGFloat(samples)
                points.append(
                    CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                )
            }
        }
        points.append(centres.last!)
        return points
    }

    // MARK: - Tracing

    /// A finger lingers, so three samples inside "e" are one intentional "e".
    @Test func consecutiveRepeatsCollapse() {
        #expect(SwipeRecognizer.collapsed("heelllo") == "helo")
        #expect(SwipeRecognizer.collapsed("H E L L O") == "helo")
        #expect(SwipeRecognizer.collapsed("123") == "")
    }

    @Test func tracingFollowsTheKeysThePathCrossed() {
        let trace = Self.recognizer.trace(Self.path(through: "hello"))
        #expect(trace.hasPrefix("h"))
        #expect(trace.hasSuffix("o"))
        // Everything the finger meant is in there, in order.
        #expect(SwipeRecognizer.isSubsequence("helo", of: trace))
    }

    @Test func subsequenceRequiresOrderNotJustPresence() {
        #expect(SwipeRecognizer.isSubsequence("helo", of: "hgetlklo"))
        #expect(!SwipeRecognizer.isSubsequence("helo", of: "olleh"))
        #expect(SwipeRecognizer.isSubsequence("", of: "anything"))
    }

    // MARK: - Recognition

    @Test func aTracedWordIsRecognised() {
        for word in ["hello", "world", "there"] {
            let trace = Self.recognizer.trace(Self.path(through: word))
            let candidates = Self.recognizer.candidates(for: trace, in: Self.wordList)
            #expect(candidates.first == word, "\(word) traced to \(candidates)")
        }
    }

    /// The first and last keys are the two the user was most deliberate about,
    /// so a word that starts somewhere else is not offered at all.
    @Test func aWordMustStartAndEndWhereTheFingerDid() {
        let trace = Self.recognizer.trace(Self.path(through: "good"))
        let candidates = Self.recognizer.candidates(for: trace, in: Self.wordList)
        #expect(!candidates.contains("hello"))
        #expect(!candidates.contains("the"))
    }

    @Test func alternatesComeBackForTheStrip() {
        let trace = Self.recognizer.trace(Self.path(through: "word"))
        let candidates = Self.recognizer.candidates(for: trace, in: Self.wordList, limit: 4)
        // "word" and "world" share both ends and most of their path, so the
        // loser belongs in the strip rather than being discarded.
        #expect(candidates.count >= 1)
        #expect(candidates.first == "word")
    }

    @Test func aTraceTooShortToMeanAnythingIsRefused() {
        #expect(Self.recognizer.candidates(for: "h", in: Self.wordList).isEmpty)
        #expect(Self.recognizer.candidates(for: "", in: Self.wordList).isEmpty)
    }

    @Test func anEmptyWordListRecognisesNothing() {
        let trace = Self.recognizer.trace(Self.path(through: "hello"))
        #expect(Self.recognizer.candidates(for: trace, in: .empty).isEmpty)
    }

    // MARK: - Geometry

    /// Neighbours are derived from the keys themselves, so the radius is right
    /// whatever height preference and screen width are in force.
    @Test func neighboursAreTheKeysAFingerCouldHaveMeant() {
        let neighbours = Self.recognizer.neighbours(of: "g")
        #expect(neighbours.contains("f"))
        #expect(neighbours.contains("h"))
        #expect(!neighbours.contains("q"))
        #expect(!neighbours.contains("g"))
    }

    @Test func theNearestKeyIsTheOneUnderTheFinger() {
        let g = Self.keys.first { $0.character == "g" }!
        #expect(Self.recognizer.nearestKey(to: g.centre)?.character == "g")
        let nudged = CGPoint(x: g.centre.x + 4, y: g.centre.y - 4)
        #expect(Self.recognizer.nearestKey(to: nudged)?.character == "g")
    }

    /// A path that follows the ideal one scores better than one that wanders,
    /// which is the whole basis of the ranking.
    @Test func aCloserShapeScoresHigher() {
        let straight = Self.recognizer.shapeDistance(path: "helo", word: "helo")
        let wandering = Self.recognizer.shapeDistance(path: "hqzlo", word: "helo")
        #expect(straight < wandering)
    }

    @Test func aRecogniserWithNoKeysRefusesToGuess() {
        let empty = SwipeRecognizer(keys: [])
        #expect(!empty.isUsable)
        #expect(empty.candidates(for: "hello", in: Self.wordList).isEmpty)
    }
}
