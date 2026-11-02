import Foundation

/// The MindType v2.0 recipe, ported from `tools/grammar-eval/infer.py`.
///
/// Pure Swift: the model is a `Logits` closure, so everything here — word
/// split, alignment, KEEP bias, guard, edits and passes — is tested against
/// `assets/grammar/parity_fixtures.json` without ONNX Runtime. Kept in step
/// with `GrammarTagger.kt`; the README beside `infer.py` says why each rule
/// exists.
final class GrammarTagger: @unchecked Sendable {
    /// Label scores for the tokens at `rows` of `ids`, one row each.
    typealias Logits = (_ ids: [Int64], _ rows: [Int32]) throws -> [[Float]]

    /// "Balanced": the bias v2.0 was tuned for.
    static let keepBias: Float = 3.0
    /// "Only sure fixes": fewer, safer edits.
    static let sureKeepBias: Float = 4.0
    /// A Writing check the user asked for (the keyboard's button, the Writing
    /// check screen). Every edit becomes a card the user accepts or dismisses,
    /// so a few more wrong ones are worth the many more right ones. Never used
    /// where nothing is shown first (dictation). Mirrors `THOROUGH_KEEP_BIAS`.
    static let thoroughKeepBias: Float = 1.0
    static let maxPasses = 3
    /// The position table holds 160; one goes to `[BOS]`.
    static let maxTokens = 150
    static let bosID = 1
    static let labelCount = 15_000

    struct Word: Equatable {
        var text: String
        var space: String
        var isProtected = false
    }

    struct Decision: Equatable {
        let word: String
        let label: String
        let chosen: String
    }

    struct Pass: Equatable {
        let words: [String]
        let ids: [Int64]
        let starts: [Int]
        let decisions: [Decision]
    }

    private let tokenizer: ByteLevelBpe
    private let labels: [String]
    private let pairs: Set<String>
    private let logits: Logits
    private let keepBias: Float

    init(
        tokenizer: ByteLevelBpe,
        labels: [String],
        plausiblePairs: [String],
        keepBias: Float = GrammarTagger.keepBias,
        logits: @escaping Logits
    ) {
        self.tokenizer = tokenizer
        self.labels = labels
        pairs = Set(plausiblePairs)
        self.keepBias = keepBias
        self.logits = logits
    }

    /// Corrects `text`. `vocabulary` words are never changed. A sentence
    /// that would start after `deadline` (an uptime in nanoseconds) is left
    /// as it was, so a long dictation keeps every sentence finished in time.
    /// `bias` is added to KEEP's score: `keepBias` is "Balanced",
    /// `sureKeepBias` "Only sure fixes", `thoroughKeepBias` a check the user
    /// asked for; nil uses the one this tagger was made with.
    func correct(
        _ text: String,
        vocabulary: Set<String> = [],
        deadline: UInt64 = .max,
        bias: Float? = nil,
        trace: ((_ passes: [Pass]) -> Void)? = nil
    ) throws -> String {
        let bias = bias ?? keepBias
        // Apostrophes compared straight, as the model reads them: a word saved
        // as "don't" also keeps "don’t".
        let lowered = Set(vocabulary.map { $0.lowercased().replacingOccurrences(of: "’", with: "'") })
        let masked = ProtectedSpans.mask(text)
        var out = ""
        for (lead, sentence) in Self.splitSentences(masked.text) {
            out += lead
            if DispatchTime.now().uptimeNanoseconds > deadline {
                out += sentence
                continue
            }
            var passes: [Pass] = []
            out += try correctSentence(
                sentence, vocabulary: lowered, spans: masked.tokens, passes: &passes, deadline: deadline, bias: bias
            )
            trace?(passes)
        }
        let restored = masked.restore(out)
        return restored.contains(where: \.isLetter) ? restored : text
    }

    private func correctSentence(
        _ sentence: String,
        vocabulary: Set<String>,
        spans: [String],
        passes: inout [Pass],
        deadline: UInt64,
        bias: Float
    ) throws -> String {
        var words = Self.splitWords(sentence)
        guard words.contains(where: { Self.containsLatinWord($0.text) }) else { return sentence }
        for pass in 0..<Self.maxPasses {
            // A later pass only refines the last one, so out of time it stops
            // with what the earlier passes already settled.
            if pass > 0, DispatchTime.now().uptimeNanoseconds > deadline { break }
            var chosen = Array(repeating: "KEEP", count: words.count)
            for range in chunk(words, spans: spans) {
                // Out of time mid-sentence: the rest of this pass keeps its words.
                if DispatchTime.now().uptimeNanoseconds > deadline { break }
                // One word longer than the model can read: leave it.
                if range.count == 1, oversized(words[range.lowerBound], spans: spans) { continue }
                let tagged = try tag(words, range, vocabulary: vocabulary, spans: spans, bias: bias)
                passes.append(tagged)
                for (i, decision) in tagged.decisions.enumerated() { chosen[range.lowerBound + i] = decision.chosen }
            }
            let next = apply(words, chosen: chosen)
            let changed = next.map(\.text) != words.map(\.text)
            words = next
            if !changed { break }
        }
        let trailing = sentence.reversed().prefix { $0.isWhitespace }
        return words.map { $0.space + $0.text }.joined() + String(trailing.reversed())
    }

    // MARK: - Tokenization

    /// What the model reads for a word: the hidden span, and straight apostrophes.
    func modelText(_ word: Word, spans: [String]) -> String {
        if let index = Self.placeholderIndex(word.text), spans.indices.contains(index) {
            return spans[index]
        }
        return word.text.replacingOccurrences(of: "’", with: "'")
    }

    /// Every word, the first included, as " " + word; the label is read at its first subtoken.
    func encodeWord(_ text: String) -> [Int] { tokenizer.encode(" " + text) }

    func encode(_ texts: [String]) -> (ids: [Int64], starts: [Int]) {
        var ids: [Int64] = [Int64(Self.bosID)]
        var starts: [Int] = []
        for text in texts {
            starts.append(ids.count)
            ids += encodeWord(text).map(Int64.init)
        }
        return (ids, starts)
    }

    private func oversized(_ word: Word, spans: [String]) -> Bool {
        encodeWord(modelText(word, spans: spans)).count > Self.maxTokens
    }

    /// Word ranges of at most `maxTokens` tokens each. A word that alone is
    /// longer (a long URL fed as itself) gets a range of its own, which
    /// `correctSentence` leaves alone rather than overflow the model's 160
    /// positions.
    private func chunk(_ words: [Word], spans: [String]) -> [Range<Int>] {
        var chunks: [Range<Int>] = []
        var start = 0
        var tokens = 0
        for (i, word) in words.enumerated() {
            let count = encodeWord(modelText(word, spans: spans)).count
            if i > start, tokens + count > Self.maxTokens {
                chunks.append(start..<i)
                start = i
                tokens = 0
            }
            if count > Self.maxTokens {
                if i > start { chunks.append(start..<i) }
                chunks.append(i..<(i + 1))
                start = i + 1
                tokens = 0
            } else {
                tokens += count
            }
        }
        if start < words.count { chunks.append(start..<words.count) }
        return chunks
    }

    // MARK: - One pass

    /// Runs the words in `range` through the model. The guard sees the whole
    /// sentence, so a name or a preposition at a chunk's edge keeps the
    /// protection it has anywhere else.
    private func tag(
        _ words: [Word], _ range: Range<Int>, vocabulary: Set<String>, spans: [String], bias: Float
    ) throws -> Pass {
        let texts = words[range].map { modelText($0, spans: spans) }
        let (ids, starts) = encode(texts)
        let rows = try logits(ids, starts.map(Int32.init))
        let decisions = starts.indices.map { i -> Decision in
            let row = rows[i]
            var best = 0
            var bestScore = row[0] + bias
            for k in 1..<row.count where row[k] > bestScore {
                bestScore = row[k]
                best = k
            }
            let label = labels[best]
            return Decision(word: texts[i], label: label, chosen: allow(words, range.lowerBound + i, label, vocabulary))
        }
        return Pass(words: texts, ids: ids, starts: starts, decisions: decisions)
    }

    // MARK: - The guard

    private func frozen(_ words: [Word], _ i: Int, _ vocabulary: Set<String>) -> Bool {
        let word = words[i]
        if word.isProtected { return true }
        if !Self.isLatinWord(word.text) { return !Self.punctuation.contains(word.text) }
        if vocabulary.contains(word.text.lowercased().replacingOccurrences(of: "’", with: "'")) { return true }
        if word.text.dropFirst().contains(where: \.isUppercase) { return true }
        if word.text.first?.isUppercase == true, !Self.sentenceStart(words, i) {
            return !Self.isPronounI(word.text)
        }
        return false
    }

    func allow(_ words: [Word], _ i: Int, _ label: String, _ vocabulary: Set<String>) -> String {
        if label == "KEEP" { return label }
        if frozen(words, i, vocabulary) { return "KEEP" }
        let source = words[i].text
        let lower = source.lowercased()
        let next = i + 1 < words.count ? words[i + 1].text : ""
        if Self.prepositions.contains(lower), !label.hasPrefix("APPEND_"), let first = next.first,
           first.isUppercase || next.contains(where: \.isNumber) || Self.guardNext.contains(first)
            || Self.placeholderIndex(next) != nil
        {
            return "KEEP"
        }
        if label.hasPrefix("REPLACE_"), lower == "too", next.isEmpty || Self.punctuation.contains(next) {
            return "KEEP"
        }
        if label == "DELETE" { return Self.deletable.contains(lower) ? label : "KEEP" }
        if label.hasPrefix("$CASE_") {
            let lowercase = source.allSatisfy { !$0.isLetter || $0.isLowercase }
            if label == "$CASE_CAP", lowercase, Self.sentenceStart(words, i) || source == "i" { return label }
            if label == "$CASE_UP", source == "i" { return label }
            return "KEEP"
        }
        if label.hasPrefix("APPEND_") {
            let added = String(label.dropFirst("APPEND_".count))
            return Self.appendable.contains(added.lowercased()) || Self.punctuation.contains(added) ? label : "KEEP"
        }
        if label.hasPrefix("REPLACE_") {
            return plausible(source, String(label.dropFirst("REPLACE_".count))) ? label : "KEEP"
        }
        return "KEEP"
    }

    private func plausible(_ source: String, _ target: String) -> Bool {
        let a = source.lowercased().replacingOccurrences(of: "’", with: "'")
        let b = target.lowercased()
        if a == b { return true }
        if pairs.contains("\(a)→\(b)") || Self.confusion.contains("\(a)→\(b)") { return true }
        guard Self.isLatinWord(target) else { return false }
        return min(a.count, b.count) >= 4 && Self.editDistance(a, b) <= 2
    }

    // MARK: - Apply

    func apply(_ words: [Word], chosen: [String]) -> [Word] {
        var out: [Word] = []
        for (i, word) in words.enumerated() {
            let label = chosen[i]
            switch label {
            case "KEEP": out.append(word)
            case "DELETE": break
            case "$CASE_CAP": out.append(Word(text: word.text.prefix(1).uppercased() + word.text.dropFirst(), space: word.space))
            case "$CASE_LOW": out.append(Word(text: word.text.lowercased(), space: word.space))
            case "$CASE_UP": out.append(Word(text: word.text.uppercased(), space: word.space))
            default:
                if label.hasPrefix("REPLACE_") {
                    var target = Self.matchCase(
                        word.text, String(label.dropFirst("REPLACE_".count)), atStart: Self.sentenceStart(words, i)
                    )
                    if word.text.contains("’") { target = target.replacingOccurrences(of: "'", with: "’") }
                    out.append(Word(text: target, space: word.space))
                } else if label.hasPrefix("APPEND_") {
                    out.append(word)
                    let added = String(label.dropFirst("APPEND_".count))
                    out.append(Word(text: added, space: Self.punctuation.contains(added) || added.hasPrefix("'") ? "" : " "))
                } else {
                    out.append(word)
                }
            }
        }
        if let first = words.first, !out.isEmpty, out[0].space != first.space {
            out[0].space = first.space
        }
        if let first = words.first, !out.isEmpty, first.text.first?.isUppercase == true,
           out[0].text.first?.isLowercase == true, !out[0].isProtected
        {
            out[0] = Word(text: out[0].text.prefix(1).uppercased() + out[0].text.dropFirst(), space: out[0].space)
        }
        return out
    }

    // MARK: - Tables

    private static let word = try! NSRegularExpression(
        pattern: "\(ProtectedSpans.open)\\d+\(ProtectedSpans.close)|[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)*|\\S"
    )
    private static let placeholder = try! NSRegularExpression(
        pattern: "^\(ProtectedSpans.open)(\\d+)\(ProtectedSpans.close)$"
    )
    private static let latinWord = try! NSRegularExpression(pattern: "^[A-Za-z]+(?:['’][A-Za-z]+)*$")
    private static let latinWordInside = try! NSRegularExpression(pattern: "[A-Za-z]+(?:['’][A-Za-z]+)*")
    private static let sentenceEnd = try! NSRegularExpression(pattern: "(?<=[.!?])\\s+")
    private static let punctuation: Set<String> = [".", ",", "!", "?", ";", ":"]
    private static let guardNext: Set<Character> = ["$", "£", "€", "#", "@"]
    private static let deletable: Set<String> = ["more", "most", "of", "the", "a", "an", "to", "is", "are"]
    private static let appendable = Set(
        "a an the to is are am was were be have has 's 'm 're 've 'll 'd".split(separator: " ").map(String.init)
    )
    private static let prepositions = Set(
        ("about above across after against along around at before behind below beside between by down "
            + "during for from in inside into near of off on onto out over past since through till to toward "
            + "towards under until up upon with within without").split(separator: " ").map(String.init)
    )
    private static let confusionSets: [[String]] = [
        ["a", "an", "the"],
        ["is", "are", "am", "was", "were", "be", "been", "being"],
        ["has", "have", "had"],
        ["do", "does", "did", "done"],
        ["don't", "doesn't", "didn't"],
        ["isn't", "aren't", "wasn't", "weren't"],
        ["hasn't", "haven't"],
        ["their", "there", "they're"],
        ["its", "it's"],
        ["your", "you're"],
        ["whose", "who's"],
        ["were", "we're", "where"],
        ["then", "than"],
        ["to", "too", "two"],
        ["of", "have"],
        ["lose", "loose"],
        ["affect", "effect"],
        ["accept", "except"],
        ["fewer", "less"],
        ["lie", "lay", "lying", "laying"],
        ["me", "i"],
        ["him", "he"],
        ["her", "she"],
        ["them", "they"],
        ["us", "we"],
    ]
    private static let confusion: Set<String> = Set(confusionSets.flatMap { set in
        set.flatMap { a in set.filter { $0 != a }.map { "\(a)→\($0)" } }
    })

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func isLatinWord(_ text: String) -> Bool { matches(latinWord, text) }
    private static func containsLatinWord(_ text: String) -> Bool { matches(latinWordInside, text) }

    private static func placeholderIndex(_ text: String) -> Int? {
        let string = text as NSString
        guard let match = placeholder.firstMatch(in: text, range: NSRange(location: 0, length: string.length))
        else { return nil }
        return Int(string.substring(with: match.range(at: 1)))
    }

    static func splitWords(_ sentence: String) -> [Word] {
        let string = sentence as NSString
        var position = 0
        return word.matches(in: sentence, range: NSRange(location: 0, length: string.length)).map { match in
            let text = string.substring(with: match.range)
            let space = string.substring(with: NSRange(location: position, length: match.range.location - position))
            position = match.range.location + match.range.length
            return Word(text: text, space: space, isProtected: placeholderIndex(text) != nil)
        }
    }

    /// (whitespace before, sentence) pairs that rejoin to `text`.
    static func splitSentences(_ text: String) -> [(String, String)] {
        let string = text as NSString
        var out: [(String, String)] = []
        var lead = ""
        var start = 0
        for match in sentenceEnd.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            out.append((lead, string.substring(with: NSRange(location: start, length: match.range.location - start))))
            lead = string.substring(with: match.range)
            start = match.range.location + match.range.length
        }
        out.append((lead, string.substring(from: start)))
        return out
    }

    private static func sentenceStart(_ words: [Word], _ i: Int) -> Bool {
        var j = i - 1
        while j >= 0, ["\"", "“", "'", "("].contains(words[j].text) { j -= 1 }
        return j < 0 || [".", "!", "?"].contains(words[j].text)
    }

    private static func isPronounI(_ text: String) -> Bool {
        text == "I" || text.hasPrefix("I'") || text.hasPrefix("I’")
    }

    private static func matchCase(_ source: String, _ target: String, atStart: Bool) -> String {
        if source.count > 1, source.allSatisfy({ !$0.isLetter || $0.isUppercase }) { return target.uppercased() }
        if source.first?.isUppercase == true, atStart || isPronounI(source) {
            return target.prefix(1).uppercased() + target.dropFirst()
        }
        if source.first?.isLowercase == true, target.first?.isUppercase == true, !isPronounI(target) {
            return target.prefix(1).lowercased() + target.dropFirst()
        }
        return target
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
