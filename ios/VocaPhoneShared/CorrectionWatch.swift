import Foundation

/// A spelling the user fixed in a dictation, ready to be suggested. Only this
/// pair leaves the keyboard: never the text around it.
///
/// `heardIsWord` and `namesTerm` are decided where the word list is loaded
/// (the keyboard), so the app that stores the pair needs no list of its own.
struct LearnedCorrection: Codable, Equatable, Sendable {
    let heard: String
    let corrected: String
    /// `heard` is one ordinary word: learning it as a replacement would
    /// rewrite ordinary speech.
    let heardIsWord: Bool
    /// `corrected` has a capital or a word the list doesn't know: a name or a
    /// term, not grammar.
    let namesTerm: Bool
}

/// Follows one dictation in the field it was typed into, and works out what
/// the user respelled in it (`CorrectionLearner`).
///
/// The keyboard hands it what it already reads around the cursor as the user
/// edits. The first reading after the insertion is the baseline: the
/// dictation and the text either side of it. Each later reading finds the
/// dictation again by that surrounding text (`DictatedSpan`) and keeps what
/// the learner makes of it; a reading where it cannot be found — the message
/// was sent and the field cleared, the user moved on — leaves the last result
/// standing. `finish()` hands that result over and forgets everything.
///
/// Text is held in memory only, for one dictation, and never stored. Not
/// thread-safe: one caller at a time. Mirrors `CorrectionWatch.kt`.
final class CorrectionWatch {
    /// Longer dictations are documents, not messages, and not worth reading back.
    static let maximumDictation = 1_000

    private let isKnownWord: (String) -> Bool
    private var dictated: String?
    private var baseline: DictatedSpan?
    private var pending: [LearnedCorrection] = []

    init(isKnownWord: @escaping (String) -> Bool) {
        self.isKnownWord = isKnownWord
    }

    /// Whether a dictation is being followed.
    var isActive: Bool { dictated != nil }

    /// Characters to read either side of the cursor while following `inserted`.
    static func readLimit(_ inserted: String) -> Int {
        let length = min(inserted.trimmingCharacters(in: .whitespacesAndNewlines).count, maximumDictation)
        return length + 2 * DictatedSpan.anchorLength + 64
    }

    /// Starts following `inserted`, replacing any dictation followed before
    /// (call `finish()` first to keep what it found). Returns false, following
    /// nothing, for text not worth it: blank, very long, or not in the
    /// language the word list knows, where respelling and rewording cannot be
    /// told apart.
    @discardableResult
    func start(_ inserted: String) -> Bool {
        clear()
        let text = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= Self.maximumDictation,
              CorrectionLearner.readsAsKnownLanguage(text, isKnownWord: isKnownWord)
        else { return false }
        dictated = text
        return true
    }

    /// One reading of the field around the cursor.
    ///
    /// - Parameters:
    ///   - reachesStart: `before` begins at the start of the field.
    ///   - reachesEnd: `after` ends at the end of the field.
    func read(before: String, after: String, reachesStart: Bool = true, reachesEnd: Bool = true) {
        guard let text = dictated else { return }
        guard let span = baseline else {
            // The first reading is taken just after the insertion, the cursor
            // at its end; a dictation not there was not inserted as expected.
            baseline = DictatedSpan.baseline(
                dictated: text, before: before, after: after, reachesStart: reachesStart, reachesEnd: reachesEnd
            )
            if baseline == nil { clear() }
            return
        }
        guard let found = span.corrections(
            before: before, after: after, reachesStart: reachesStart, reachesEnd: reachesEnd, isKnownWord: isKnownWord
        ) else { return }
        pending = found.map { correction in
            LearnedCorrection(
                heard: correction.heard,
                corrected: correction.corrected,
                heardIsWord: CorrectionLearner.isOrdinaryWord(correction.heard, isKnownWord: isKnownWord),
                namesTerm: CorrectionLearner.namesATerm(correction.corrected, isKnownWord: isKnownWord)
            )
        }
    }

    /// What the last reading that found the dictation learned; stops
    /// following it.
    func finish() -> [LearnedCorrection] {
        let found = pending
        clear()
        return found
    }

    private func clear() {
        dictated = nil
        baseline = nil
        pending = []
    }
}

/// Where a dictation sits in its field, told by the text either side of it,
/// so it can be found again after the user has edited it — and the cursor,
/// and with it the window of text the keyboard can read, has moved.
///
/// `before` and `after` are the anchors: up to `anchorLength` characters next
/// to the dictation. `beforeIsFieldStart` says the field starts where
/// `before` does, so the anchor must sit at the start of a reading that
/// reaches the field's start; likewise `afterIsFieldEnd`. Mirrors
/// `DictatedSpan` in `CorrectionWatch.kt`.
struct DictatedSpan: Equatable {
    /// Characters either side of the dictation that find it again.
    static let anchorLength = 24
    private static let maximumOccurrences = 8

    let dictated: String
    let before: String
    let after: String
    let beforeIsFieldStart: Bool
    let afterIsFieldEnd: Bool

    /// The dictation in a reading taken just after it was typed, the cursor
    /// at its end (a space after it allowed), or nil when it isn't there.
    static func baseline(
        dictated: String, before: String, after: String, reachesStart: Bool, reachesEnd: Bool
    ) -> DictatedSpan? {
        let window = Array(before + after)
        let caret = before.count
        guard let range = CorrectionLearner.locate(Array(dictated), in: window, caretLocation: caret),
              (0...2).contains(caret - range.upperBound)
        else { return nil }
        let fullBefore = window[..<range.lowerBound]
        let fullAfter = window[range.upperBound...]
        return DictatedSpan(
            dictated: dictated,
            before: String(fullBefore.suffix(anchorLength)),
            after: String(fullAfter.prefix(anchorLength)),
            beforeIsFieldStart: reachesStart && fullBefore.count <= anchorLength,
            afterIsFieldEnd: reachesEnd && fullAfter.count <= anchorLength
        )
    }

    /// What the learner makes of the dictation as the field now reads, or
    /// nil when it can't be found with confidence: an anchor is gone or
    /// appears in more than one place with different text between, or what
    /// is between no longer looks like the dictation edited.
    func corrections(
        before windowBefore: String,
        after windowAfter: String,
        reachesStart: Bool,
        reachesEnd: Bool,
        isKnownWord: (String) -> Bool
    ) -> [CorrectionLearner.Correction]? {
        guard let edited = edited(in: windowBefore + windowAfter, reachesStart: reachesStart, reachesEnd: reachesEnd)
        else { return nil }
        let old = before + dictated + after
        let new = before + edited + after
        if old == new { return [] }
        return CorrectionLearner.corrections(
            inserted: dictated, before: old, after: new,
            caretLocation: before.count + dictated.count, isKnownWord: isKnownWord
        )
    }

    /// The dictation as it reads in `window` now; see `corrections`.
    func edited(in text: String, reachesStart: Bool, reachesEnd: Bool) -> String? {
        let window = Array(text)
        let starts = anchorEnds(in: window, reachesStart: reachesStart)
        let ends = anchorStarts(in: window, reachesEnd: reachesEnd)
        guard !starts.isEmpty, !ends.isEmpty else { return nil }
        let longest = dictated.count * 2 + 40
        var regions = Set<String>()
        // Only anchors that are each other's nearest: in repetitive text an
        // earlier copy of the left anchor, or a later one of the right, would
        // otherwise frame the dictation plus a sentence beside it.
        for end in ends {
            guard let start = starts.last(where: { $0 <= end }),
                  ends.first(where: { $0 >= start }) == end,
                  end - start <= longest
            else { continue }
            let region = String(window[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if CorrectionLearner.isStillDictation(region, of: dictated) { regions.insert(region) }
        }
        return regions.count == 1 ? regions.first : nil
    }

    /// Offsets in `window` where the dictation could start.
    private func anchorEnds(in window: [Character], reachesStart: Bool) -> [Int] {
        let anchor = Array(before)
        if beforeIsFieldStart, reachesStart {
            return window.starts(with: anchor) ? [anchor.count] : []
        }
        guard !anchor.isEmpty else { return [] }
        return Self.occurrences(of: anchor, in: window).map { $0 + anchor.count }
    }

    /// Offsets in `window` where the dictation could end.
    private func anchorStarts(in window: [Character], reachesEnd: Bool) -> [Int] {
        let anchor = Array(after)
        if afterIsFieldEnd, reachesEnd {
            guard anchor.count <= window.count, Array(window.suffix(anchor.count)) == anchor else { return [] }
            return [window.count - anchor.count]
        }
        guard !anchor.isEmpty else { return [] }
        return Self.occurrences(of: anchor, in: window)
    }

    private static func occurrences(of needle: [Character], in haystack: [Character]) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var found: [Int] = []
        for start in 0...(haystack.count - needle.count) where found.count < maximumOccurrences {
            if haystack[start] == needle[0], Array(haystack[start..<(start + needle.count)]) == needle {
                found.append(start)
            }
        }
        return found
    }
}
