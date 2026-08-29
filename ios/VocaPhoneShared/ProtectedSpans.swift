import Foundation

/// The runs of a transcript that no text stage may edit: URLs, email addresses,
/// bare domains, decimals and times, ordinals, and dotted initialisms.
///
/// Every stage that rewrites punctuation has the same problem — `example.com`
/// ends in a full stop that is not a sentence, `3.5` contains one that is not a
/// mark at all — so they all mask first, work on the masked text, and restore
/// last. The placeholder is a private-use scalar pair rather than a word, so a
/// stage that lowercases or capitalizes cannot damage it and a stage that splits
/// on letters cannot split it.
struct ProtectedSpans {
    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"

    let text: String
    let tokens: [String]

    /// A bare hostname, recognized by the case of its last label rather than by
    /// a list of top-level domains.
    ///
    /// An allowlist cannot work: there are roughly 1,500 top-level domains, and
    /// every one left off it — `example.museum` — gets its dot read as sentence
    /// punctuation and the address split in half. Matching *any* dotted pair
    /// instead has the opposite fault: it masks `report.Then` in "I finished
    /// the report.Then I left", and the missing space can never be repaired.
    ///
    /// The whole signal is in the label **after** the final dot. A top-level
    /// domain is written in lowercase; a full stop that ended a sentence is
    /// followed by a capital. Nothing before that dot carries information —
    /// requiring the name to be lowercase too only loses `Example.museum` —
    /// so this asks about the last label and nothing else. The leading `\b`
    /// keeps it from matching the tail of a longer word.
    ///
    /// All caps counts too, so `NASA.GOV` survives. What that cannot be is a
    /// sentence boundary: an engine that shouts the word after a full stop
    /// shouted the one before it as well, and `report.THEN` is not a shape any
    /// of them produce. Title Case is the one that stays out — `report.Then`
    /// is the sentence boundary this whole clause exists to preserve.
    ///
    /// One thing is left over: `report.then`, an all-lowercase run-on from an
    /// engine that emits a full stop but no capital, is masked as though it
    /// were a hostname. That shape is genuinely ambiguous, and a missing space
    /// is a blemish where a broken address is data loss.
    private static let hostname = "\\b(?:[\\w-]+\\.)+(?:[a-z]{2,24}|[A-Z]{2,24})\\b"

    /// A path may contain dots; it may not end on the full stop that ends the
    /// sentence the address is sitting in.
    private static let path = "(?:/[^\\s]*[^\\s.,;:!?\\\"“”'\\)\\]])?"

    private static let pattern =
        "((?i:https?)://[^\\s]+[^\\s.,;:!?\\\"“”'\\)\\]]"
        + "|[\\w.+-]+@(?:[\\w-]+\\.)+[A-Za-z]{2,}"
        + "|" + hostname + path
        + "|\\d+(?:[.,:/]\\d+)+"
        + "|\\d+(?i:st|nd|rd|th)\\b"
        + "|(?:[A-Za-z]\\.){2,})"

    private static let expression = try? NSRegularExpression(pattern: pattern)
    private static let placeholder = try? NSRegularExpression(
        pattern: "\u{E000}(\\d+)\u{E001}"
    )

    static func mask(_ text: String) -> ProtectedSpans {
        guard let expression else { return ProtectedSpans(text: text, tokens: []) }
        let string = text as NSString
        let matches = expression.matches(
            in: text, range: NSRange(location: 0, length: string.length)
        )
        let result = NSMutableString(string: text)
        for index in matches.indices.reversed() {
            result.replaceCharacters(
                in: matches[index].range,
                with: "\(open)\(index)\(close)"
            )
        }
        return ProtectedSpans(
            text: String(result),
            tokens: matches.map { string.substring(with: $0.range) }
        )
    }

    /// Puts the original spans back. Takes the text rather than reading
    /// ``text``, because the caller has rewritten everything around them.
    func restore(_ masked: String) -> String {
        guard let placeholder = Self.placeholder else { return masked }
        let string = masked as NSString
        let matches = placeholder.matches(
            in: masked, range: NSRange(location: 0, length: string.length)
        )
        let result = NSMutableString(string: masked)
        for match in matches.reversed() {
            let index = Int(string.substring(with: match.range(at: 1))) ?? -1
            guard tokens.indices.contains(index) else { continue }
            result.replaceCharacters(in: match.range, with: tokens[index])
        }
        return String(result)
    }

    /// Applies `transform` to everything that is not a placeholder. Case
    /// changes have to skip them: the digits inside would survive, but the
    /// scalars are the only thing ``restore(_:)`` can match on.
    static func mapOutsidePlaceholders(
        _ text: String,
        _ transform: (String) -> String
    ) -> String {
        guard let placeholder else { return transform(text) }
        let string = text as NSString
        let matches = placeholder.matches(
            in: text, range: NSRange(location: 0, length: string.length)
        )
        var result = ""
        var cursor = 0
        for match in matches {
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            result += transform(string.substring(with: before))
            result += string.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += transform(string.substring(from: cursor))
        return result
    }

    /// Whether `character` opens a placeholder, for the stages that walk
    /// characters and have to step over one whole.
    static func isPlaceholderStart(_ character: Character) -> Bool { character == open }
}
