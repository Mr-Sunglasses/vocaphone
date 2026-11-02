import Foundation

/// One Writing check suggestion, Grammarly's card in data. `start..<end` is
/// the UTF-16 range `replacement` replaces, whitespace included where a word
/// is added or removed; `markStart..<markEnd` is the word to underline. A nil
/// `replacement` is information only. Mirrors WritingSuggestion.kt.
struct WritingSuggestion: Equatable, Codable, Sendable {
    /// Where a suggestion came from: the grammar model, a rule, the text's shape, or the spelling dictionary.
    enum Source: String, Codable, Sendable { case model, rule, text, dictionary }

    var start: Int
    var end: Int
    var original: String
    var replacement: String?
    var markStart: Int
    var markEnd: Int
    var kind: String
    var category: WritingCategory
    var title: String
    var message: String
    /// Spelling, punctuation and the like: safe to accept all at once.
    var mechanical: Bool
    var source: Source
    /// The rule's id for `.rule`.
    var rule: String?

    /// The words as typed; for a removal, only the words removed, not a comma or space taken along.
    var shownOriginal: String {
        if let replacement, replacement.allSatisfy(\.isWhitespace), start <= markStart, markStart < markEnd, markEnd <= end {
            return original.utf16Slice(markStart - start, markEnd - start).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return original.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var shownReplacement: String? { replacement?.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What a chip says: the words as typed and what they become.
    var label: String {
        guard let replacement = shownReplacement else { return title }
        if replacement.isEmpty { return "Remove “\(shownOriginal)”" }
        if shownOriginal.isEmpty { return "Add “\(replacement)”" }
        return "\(shownOriginal) → \(replacement)"
    }

    /// The same change anywhere in a field; what dismissing one remembers.
    var key: String {
        "\(kind)|\(WritingToken.normalize(shownOriginal))|\(shownReplacement.map(WritingToken.normalize) ?? "null")"
    }

    var isActionable: Bool { replacement != nil }

    func overlaps(_ other: WritingSuggestion) -> Bool {
        if start < other.end, other.start < end { return true }
        if start == end, other.start <= start, start <= other.end { return true }
        if other.start == other.end, start <= other.start, other.start <= end { return true }
        return false
    }
}

/// Turns "these tokens become this text" into a suggestion's ranges, the same
/// way for the rules and for the model's edits. Mirrors `WritingEdits` in Kotlin.
enum WritingEdits {
    struct Edit {
        let start: Int
        let end: Int
        let replacement: String
        let markStart: Int
        let markEnd: Int

        /// What a card shows as replaced, as `WritingSuggestion.shownOriginal`.
        func shownOriginal(_ text: String) -> String {
            let blank = replacement.allSatisfy(\.isWhitespace)
            return text.utf16Slice(blank ? markStart : start, blank ? markEnd : end)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Removed tokens `from..<to` become `inserted`; `floor` is the first token
    /// the edit may reach back to for its whitespace. The spaces come from both
    /// neighbours, and a phrase removed between commas takes one along, as
    /// `WritingEdits.build` in Kotlin describes.
    static func build(
        _ tokens: [WritingToken], floor: Int, from: Int, to: Int, inserted: String
    ) -> Edit {
        let removed = to > from
        if removed, !inserted.isEmpty { return replace(tokens, floor: floor, from: from, to: to, inserted: inserted) }
        if removed { return remove(tokens, floor: floor, from: from, to: to) }
        let words = WritingText.tokenize(inserted)
        let firstText = words.first?.text ?? inserted
        let lastText = words.last?.text ?? inserted
        if from > floor {
            let anchor = tokens[from - 1]
            let left = spaced(anchor.text, firstText) ? " " : ""
            let next = from < tokens.count ? tokens[from] : nil
            let right = next.map { $0.start == anchor.end && spaced(lastText, $0.text) } == true ? " " : ""
            return Edit(start: anchor.end, end: anchor.end, replacement: left + inserted + right,
                        markStart: anchor.start, markEnd: anchor.end)
        }
        let next = tokens[from]
        let right = spaced(lastText, next.text) ? " " : ""
        return Edit(start: next.start, end: next.start, replacement: inserted + right,
                    markStart: next.start, markEnd: next.end)
    }

    /// Tokens swapped for others: a space only where two words would otherwise touch.
    private static func replace(_ tokens: [WritingToken], floor: Int, from: Int, to: Int, inserted: String) -> Edit {
        let words = WritingText.tokenize(inserted)
        let first = tokens[from]
        let last = tokens[to - 1]
        let before = from > floor && from > 0 ? tokens[from - 1] : nil
        let after = to < tokens.count ? tokens[to] : nil
        let left = before.map { $0.end == first.start && $0.isWord } == true && words.first?.isWord == true ? " " : ""
        let right = after.map { $0.start == last.end && $0.isWord } == true && words.last?.isWord == true ? " " : ""
        return Edit(start: first.start, end: last.end, replacement: left + inserted + right,
                    markStart: first.start, markEnd: last.end)
    }

    private static func remove(_ tokens: [WritingToken], floor: Int, from removeFrom: Int, to removeTo: Int) -> Edit {
        let markStart = tokens[removeFrom].start
        let markEnd = tokens[removeTo - 1].end
        var from = removeFrom
        var to = removeTo
        func token(_ i: Int) -> WritingToken? { i >= 0 && i < tokens.count ? tokens[i] : nil }
        let left = from > floor ? token(from - 1) : nil
        let right = token(to)
        if left?.text == "," {
            if right?.text == ",", from - 1 > floor {
                // ", needless to say," between words: both commas go.
                from -= 1
                to += 1
            } else if right == nil || closing.contains(right!.text) {
                // ", if that makes sense." at the end: the comma goes.
                from -= 1
            }
        } else if left == nil, right?.text == "," {
            to += 1
        }
        let l = from > floor ? token(from - 1) : nil
        let r = token(to)
        let first = tokens[from]
        let last = tokens[to - 1]
        guard let l else {
            // At the start, take the space after it.
            return Edit(start: first.start, end: r?.start ?? last.end, replacement: "", markStart: markStart, markEnd: markEnd)
        }
        guard let r else {
            // At the end, take the space before it.
            return Edit(start: l.end, end: last.end, replacement: "", markStart: markStart, markEnd: markEnd)
        }
        let wanted = spaced(l.text, r.text)
        let gapBefore = first.start > l.end
        let gapAfter = r.start > last.end
        // Usually the space before goes and the one after stays.
        if gapAfter == wanted {
            return Edit(start: l.end, end: last.end, replacement: "", markStart: markStart, markEnd: markEnd)
        }
        if gapBefore == wanted {
            return Edit(start: first.start, end: r.start, replacement: "", markStart: markStart, markEnd: markEnd)
        }
        return Edit(start: l.end, end: r.start, replacement: wanted ? " " : "", markStart: markStart, markEnd: markEnd)
    }

    /// Whether a space belongs between `left` and `right`: not after "(" or a hyphen, not before "," or ")".
    private static func spaced(_ left: String, _ right: String) -> Bool {
        !opening.contains(left) && !joining.contains(left) && !joining.contains(right) && !attached.contains(right)
    }

    private static let closing: Set<String> = [".", "!", "?", ";", ":", "…"]
    private static let attached: Set<String> = [",", ".", ";", ":", "!", "?", "…", ")", "]", "}", "”", "’", "»"]
    private static let opening: Set<String> = ["(", "[", "{", "“", "‘", "«"]
    private static let joining: Set<String> = ["-", "‐", "‑", "/"]

    /// Fills `{name}` placeholders from `values`; unknown names become empty.
    static func format(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "}") else {
                out += rest[open...]
                return out
            }
            let name = after[..<close]
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                out += values[String(name)] ?? ""
            } else {
                out += rest[open...close]
            }
            rest = after[after.index(after: close)...]
        }
        return out + rest
    }
}

extension String {
    /// The UTF-16 slice `from..<to`, as `NSString` would give it.
    func utf16Slice(_ from: Int, _ to: Int) -> String {
        (self as NSString).substring(with: NSRange(location: from, length: to - from))
    }

    var utf16Length: Int { (self as NSString).length }
}
