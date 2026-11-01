import Foundation

/// Writing check (English): the whole Grammarly-style pass over a piece of
/// text, on the phone. Pure, tested against
/// `assets/grammar/writing_fixtures.json` like WritingCheck.kt, which it mirrors.
///
/// The rules run anywhere, the keyboard extension included. The grammar model
/// runs in the app and arrives as `model`: a sentence in, the corrected
/// sentence out, or nil while it loads. Nothing leaves the device.
struct WritingCheck: Sendable {
    typealias Model = (String) -> String?

    struct Options: Sendable {
        var categories: Set<WritingCategory> = Set(WritingCategory.allCases)
        /// The user's own words (custom vocabulary, snippet triggers): never flagged.
        var keep: Set<String> = []
        /// Typed text: a full stop the model adds where the text stops, and a
        /// capital on a sentence typed in lower case on purpose, are not offered.
        var typed = true
        /// Rules the user turned on that are off by default, by their `optIn` name: "serial_comma".
        var optIn: Set<String> = []
    }

    struct Tone: Equatable, Codable, Sendable {
        let id: String
        let label: String
        let emoji: String
        let score: Int
    }

    struct Stats: Equatable, Codable, Sendable {
        let words: Int
        let characters: Int
        let sentences: Int
        let readingSeconds: Int
        let speakingSeconds: Int
        /// Flesch reading ease, 0–100; nil without a sentence to measure.
        let readability: Int?
        let readabilityLabel: String?
        /// 100 less a weighted count of issues per 100 words; nil for empty text.
        let score: Int?
    }

    struct Report: Equatable, Sendable {
        let text: String
        let suggestions: [WritingSuggestion]
        let tones: [Tone]
        let stats: Stats
        /// A sentence the model was asked about came back nil: it is still loading.
        let modelPending: Bool
    }

    let rules: WritingRules

    init(rules: WritingRules) { self.rules = rules }

    func check(_ text: String, model: Model? = nil, options: Options = Options()) -> Report {
        let tokens = WritingText.tokenize(text)
        let sentences = WritingText.sentences(text, tokens)
        let protected = ProtectedSpans.ranges(text)
        let keep = Set(options.keep.map(WritingToken.normalize))
        var found: [WritingSuggestion] = []
        var pending = false

        for sentence in sentences {
            found += ruleSuggestions(text, tokens, sentence, protected, keep, options)
        }
        if let model {
            let edits = ModelEdits(rules: rules)
            for sentence in sentences {
                let words = tokens[sentence.first...sentence.last]
                let latin = words.contains { token in
                    token.hasLetter && token.text.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
                }
                if !latin { continue }
                guard let corrected = model(text.utf16Slice(sentence.start, sentence.end)) else {
                    pending = true
                    continue
                }
                found += edits.suggestions(text, tokens, sentence, corrected: corrected).filter { s in
                    keep.isDisjoint(with: Self.words(in: s.original))
                }
            }
        }
        found += longSentences(text, tokens, sentences)
        found += overusedWords(tokens, sentences, keep)

        let lowercaseStyle = text.unicodeScalars.first(where: WritingText.isLetter)?.properties.isLowercase == true
        var starts = Set<Int>()
        for s in sentences {
            var index = s.last
            for i in s.first...s.last where WritingText.isSentenceStart(tokens, s, i) && tokens[i].isWord {
                index = i
                break
            }
            starts.insert(tokens[index].start)
        }
        let kept = found
            .filter { options.categories.contains($0.category) }
            .filter { !options.typed || offeredOnTypedText($0, text, lowercaseStyle: lowercaseStyle, sentenceStarts: starts) }
        let merged = merge(kept, text)
        return Report(
            text: text, suggestions: merged, tones: tones(text, tokens),
            stats: stats(text, tokens, sentences, merged), modelPending: pending
        )
    }

    // MARK: - Rules

    private func ruleSuggestions(
        _ text: String, _ tokens: [WritingToken], _ sentence: WritingSentence, _ protected: [NSRange], _ keep: Set<String>,
        _ options: Options
    ) -> [WritingSuggestion] {
        var out: [WritingSuggestion] = []
        // Tokens a suggestion already changes. A later rule may still match
        // across them ("didnt went" is both "didnt" → "didn't" and "went" →
        // "go"), but may not change them a second time.
        var claimed = Set<Int>()
        for i in sentence.first...sentence.last {
            let start = WritingText.isSentenceStart(tokens, sentence, i)
            for index in candidates(tokens[i]) {
                let rule = rules.rules[index]
                // A rule the user turned off must not take its words from one
                // they kept: "could" is hedging, and "could helps" still needs "help".
                if !options.categories.contains(rules.kind(rule.kind).category) { continue }
                if let optIn = rule.optIn, !options.optIn.contains(optIn) { continue }
                let count = rule.match(tokens, sentence, i, rules, start: start)
                if count == 0 { continue }
                let matched = Array(tokens[i..<(i + count)])
                let touchesProtected = matched.contains { t in
                    protected.contains { t.start < $0.location + $0.length && $0.location < t.end }
                }
                if touchesProtected { continue }
                guard let found = ruleSuggestion(text, tokens, sentence, rule, i, matched, keep) else { continue }
                guard found.suggestion.isActionable else {
                    out.append(found.suggestion)
                    continue
                }
                if (found.from..<found.to).contains(where: { claimed.contains($0) }) { continue }
                out.append(found.suggestion)
                for k in found.from..<found.to { claimed.insert(k) }
                // Once this token has changed, no other rule may start here.
                if (found.from..<found.to).contains(i) { break }
            }
        }
        return out
    }

    /// A rule's suggestion and the tokens `from..<to` it changes.
    private struct Found {
        let suggestion: WritingSuggestion
        let from: Int
        let to: Int
    }

    /// The rules that could start at `token`, in the file's order.
    private func candidates(_ token: WritingToken) -> [Int] {
        let b = rules.rulesStartingWithClass
        guard let a = rules.rulesByFirstWord[token.key] else { return b }
        var out: [Int] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if j >= b.count || (i < a.count && a[i] < b[j]) {
                out.append(a[i])
                i += 1
            } else {
                out.append(b[j])
                j += 1
            }
        }
        return out
    }

    private func ruleSuggestion(
        _ text: String, _ tokens: [WritingToken], _ sentence: WritingSentence, _ rule: WritingRule,
        _ index: Int, _ matched: [WritingToken], _ keep: Set<String>
    ) -> Found? {
        let kind = rules.kind(rule.kind)
        var values: [String: String] = [:]
        for (i, t) in matched.enumerated() { values["\(i + 1)"] = t.text }
        guard let expanded = rule.expand(matched, rules) else {
            let first = matched[0]
            let last = matched[matched.count - 1]
            let original = text.utf16Slice(first.start, last.end)
            values["original"] = original
            let info = WritingSuggestion(
                start: first.start, end: last.end, original: original, replacement: nil,
                markStart: first.start, markEnd: last.end, kind: kind.id, category: kind.category, title: kind.title,
                message: WritingEdits.format(template(rule, kind), values), mechanical: kind.mechanical,
                source: .rule, rule: rule.id
            )
            return Found(suggestion: info, from: index, to: index + matched.count)
        }
        // Narrow to the tokens that change. Case counts only for a capitalization rule.
        let replacementTokens = WritingText.tokenize(expanded)
        let exact = kind.id == "capitalization"
        let m = matched.map { exact ? $0.text : $0.key }
        let r = replacementTokens.map { exact ? $0.text : $0.key }
        var pre = 0
        while pre < m.count, pre < r.count, m[pre] == r[pre] { pre += 1 }
        var suf = 0
        while suf < m.count - pre, suf < r.count - pre, m[m.count - 1 - suf] == r[r.count - 1 - suf] { suf += 1 }
        if pre == m.count, pre == r.count { return nil }
        let capitalize = WritingText.isUppercase(matched[0].text)
        values["match"] = text.utf16Slice(matched[0].start, matched[matched.count - 1].end)
        values["result"] = capitalize ? WritingText.capitalizeFirst(expanded) : expanded
        // Dropping a sentence's first words: the word that now starts it takes the capital.
        if pre == 0, capitalize, r.count == suf, suf > 0 { suf -= 1 }
        let from = index + pre
        let to = index + m.count - suf
        if tokens[from..<to].contains(where: { keep.contains($0.key) }) { return nil }
        var inserted = r.count - suf > pre
            ? expanded.utf16Slice(replacementTokens[pre].start, replacementTokens[r.count - 1 - suf].end)
            : ""
        if pre == 0, capitalize, WritingText.isLowercase(inserted) {
            inserted = WritingText.capitalizeFirst(inserted)
        }
        let edit = WritingEdits.build(tokens, floor: sentence.first, from: from, to: to, inserted: inserted)
        let original = text.utf16Slice(edit.start, edit.end)
        let shownOriginal = edit.shownOriginal(text)
        let shownReplacement = edit.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        values["original"] = shownOriginal
        values["replacement"] = shownReplacement
        values["previous"] = from > sentence.first ? tokens[from - 1].text : ""
        values["next"] = to <= sentence.last ? tokens[to].text : ""
        values["original_gloss"] = rules.glosses[WritingToken.normalize(shownOriginal)] ?? ""
        values["replacement_gloss"] = rules.glosses[WritingToken.normalize(shownReplacement)] ?? ""
        var template = template(rule, kind)
        if rule.message == nil, kind.id == "confused_words", values["original_gloss"]?.isEmpty == false,
           values["replacement_gloss"]?.isEmpty == false, let gloss = rules.messages["confused_words.gloss"] {
            template = gloss
        }
        if rule.message == nil, expanded.isEmpty, let remove = rules.messages["\(kind.id).remove"] {
            template = remove
        }
        let suggestion = WritingSuggestion(
            start: edit.start, end: edit.end, original: original, replacement: edit.replacement,
            markStart: edit.markStart, markEnd: edit.markEnd, kind: kind.id, category: kind.category, title: kind.title,
            message: WritingEdits.format(template, values), mechanical: kind.mechanical, source: .rule, rule: rule.id
        )
        return Found(suggestion: suggestion, from: from, to: to)
    }

    private func template(_ rule: WritingRule, _ kind: WritingRules.Kind) -> String {
        guard let message = rule.message else { return kind.message }
        return rules.messages[message] ?? message
    }

    // MARK: - Information only

    private func longSentences(_ text: String, _ tokens: [WritingToken], _ sentences: [WritingSentence]) -> [WritingSuggestion] {
        let kind = rules.kind("long_sentence")
        return sentences.compactMap { s in
            let words = (s.first...s.last).filter { tokens[$0].hasLetter }.count
            guard words > rules.longSentenceWords else { return nil }
            return WritingSuggestion(
                start: s.start, end: s.end, original: text.utf16Slice(s.start, s.end), replacement: nil,
                markStart: s.start, markEnd: s.end, kind: kind.id, category: kind.category, title: kind.title,
                message: WritingEdits.format(kind.message, ["count": "\(words)"]), mechanical: false,
                source: .text, rule: nil
            )
        }
    }

    /// A word used `overusedWordCount` times in a paragraph, marked where that happens; never one in `keep`.
    private func overusedWords(_ tokens: [WritingToken], _ sentences: [WritingSentence], _ keep: Set<String>) -> [WritingSuggestion] {
        let kind = rules.kind("overused_word")
        var out: [WritingSuggestion] = []
        var paragraphs: [Int] = []
        var byParagraph: [Int: [WritingSentence]] = [:]
        for s in sentences {
            if byParagraph[s.paragraph] == nil { paragraphs.append(s.paragraph) }
            byParagraph[s.paragraph, default: []].append(s)
        }
        for p in paragraphs {
            var counts: [String: Int] = [:]
            for s in byParagraph[p] ?? [] {
                for i in s.first...s.last {
                    let t = tokens[i]
                    if !t.hasLetter || t.key.count < 4 || rules.stopwords.contains(t.key) || keep.contains(t.key) { continue }
                    let n = (counts[t.key] ?? 0) + 1
                    counts[t.key] = n
                    if n == rules.overusedWordCount {
                        out.append(WritingSuggestion(
                            start: t.start, end: t.end, original: t.text, replacement: nil,
                            markStart: t.start, markEnd: t.end, kind: kind.id, category: kind.category,
                            title: kind.title,
                            message: WritingEdits.format(kind.message, ["word": t.key, "count": "\(n)"]),
                            mechanical: false, source: .text, rule: nil
                        ))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Filters and merging

    private func offeredOnTypedText(
        _ s: WritingSuggestion, _ text: String, lowercaseStyle: Bool, sentenceStarts: Set<Int>
    ) -> Bool {
        guard s.source == .model, let added = s.shownReplacement else { return true }
        if s.shownOriginal.isEmpty, !added.isEmpty, added.allSatisfy({ ".!?".contains($0) }) {
            let after = text.utf16Slice(s.end, text.utf16Length)
            let trimmed = after.drop { $0 == " " || $0 == "\t" }
            if after.allSatisfy(\.isWhitespace) || trimmed.hasPrefix("\n") { return false }
        }
        let key = WritingToken.normalize(s.shownOriginal)
        if s.kind == "capitalization", key != "i", !key.hasPrefix("i'") {
            return !lowercaseStyle && sentenceStarts.contains(s.markStart)
        }
        return true
    }

    /// Actionable suggestions never conflict: correctness first, rules before
    /// the model. Correctness is listed before the style groups, so a card
    /// about clarity or tone never comes ahead of a mistake.
    private func merge(_ found: [WritingSuggestion], _ text: String) -> [WritingSuggestion] {
        func priority(_ s: WritingSuggestion) -> Int { s.category.order * 2 + (s.source == .rule ? 0 : 1) }
        var accepted: [WritingSuggestion] = []
        let actionable = Self.stableSorted(found.filter(\.isActionable)) { a, b in
            (priority(a), a.start) < (priority(b), b.start)
        }
        for s in actionable where !accepted.contains(where: { Self.conflicts($0, s, text) }) {
            accepted.append(s)
        }
        var seen = Set<String>()
        let info = found.filter { !$0.isActionable }.filter { seen.insert("\($0.kind)|\($0.start)|\($0.end)").inserted }
        return Self.stableSorted(accepted + info) { a, b in
            (a.category.order, a.markStart, priority(a)) < (b.category.order, b.markStart, priority(b))
        }
    }

    /// Two suggestions that overlap, or one that adds words right beside the
    /// other: "thanks for invite me" can gain "the" or become "thanks for
    /// inviting me", and accepting both reads "for the inviting me".
    private static func conflicts(_ a: WritingSuggestion, _ b: WritingSuggestion, _ text: String) -> Bool {
        a.overlaps(b) || addsBeside(a, b, text) || addsBeside(b, a, text)
    }

    private static func addsBeside(_ add: WritingSuggestion, _ other: WritingSuggestion, _ text: String) -> Bool {
        guard add.shownOriginal.isEmpty, add.shownReplacement?.contains(where: \.isLetter) == true else { return false }
        let from = add.start <= other.start ? add.end : other.end
        let to = add.start <= other.start ? other.start : add.start
        return from <= to && text.utf16Slice(from, to).allSatisfy(\.isWhitespace)
    }

    private static func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { x, y in
            if less(x.element, y.element) { return true }
            if less(y.element, x.element) { return false }
            return x.offset < y.offset
        }.map(\.element)
    }

    // MARK: - Tone and statistics

    private func tones(_ text: String, _ tokens: [WritingToken]) -> [Tone] {
        if text.utf16Length < rules.toneMinimumCharacters { return [] }
        let words = tokens.filter(\.hasLetter)
        let keys = words.map(\.key)
        let joined = Array((" " + keys.joined(separator: " ") + " ").utf16)
        let exclamations = min(tokens.filter { $0.text == "!" }.count, 2)
        let questions = min(tokens.filter { $0.text == "?" }.count, 2)
        let smileys = min(text.unicodeScalars.filter { Self.smileys.contains($0.value) }.count, 2)
        let shouting = min(words.filter { w in
            w.text.unicodeScalars.count >= 3 && w.text.unicodeScalars.allSatisfy { $0.properties.isUppercase }
        }.count, 2)
        let scored = rules.tones.map { tone -> Tone in
            var score = keys.filter { tone.words.contains($0) }.count * 2
            score += tone.phrases.reduce(0) { $0 + Self.occurrences(joined, Array(" \(WritingToken.normalize($1)) ".utf16)) * 4 }
            switch tone.id {
            case "excited": score += exclamations * 2
            case "friendly": score += exclamations + smileys * 2
            case "curious": score += questions * 2
            case "urgent": score += shouting * 2
            default: break
            }
            return Tone(id: tone.id, label: tone.label, emoji: tone.emoji, score: score)
        }
        let strong = scored.filter { $0.score >= rules.toneMinimumScore }
        return Array(Self.stableSorted(strong) { $0.score > $1.score }.prefix(3))
    }

    private static func occurrences(_ h: [UInt16], _ n: [UInt16]) -> Int {
        guard !n.isEmpty, n.count <= h.count else { return 0 }
        var count = 0
        var at = 0
        while at + n.count <= h.count {
            if h[at..<(at + n.count)].elementsEqual(n) {
                count += 1
                at += n.count - 1
            } else {
                at += 1
            }
        }
        return count
    }

    private func stats(
        _ text: String, _ tokens: [WritingToken], _ sentences: [WritingSentence], _ found: [WritingSuggestion]
    ) -> Stats {
        let words = tokens.filter(\.hasLetter)
        let sentenceCount = sentences.filter { s in (s.first...s.last).contains { tokens[$0].hasLetter } }.count
        let syllables = words.reduce(0) { $0 + Self.syllables($1.key) }
        var readability: Int?
        if !words.isEmpty, sentenceCount > 0 {
            let value = 206.835 - 1.015 * (Double(words.count) / Double(sentenceCount))
                - 84.6 * (Double(syllables) / Double(words.count))
            readability = min(max(Int(value.rounded()), 0), 100)
        }
        var score: Int?
        if !words.isEmpty {
            let weight = found.reduce(0.0) { $0 + (rules.scoreWeights[$1.category] ?? 1) }
            let value = 100.0 - weight * 100.0 / Double(max(words.count, rules.scoreMinimumWords))
            score = min(max(Int(value.rounded()), 0), 100)
        }
        return Stats(
            words: words.count,
            characters: text.unicodeScalars.count,
            sentences: sentenceCount,
            readingSeconds: Int((Double(words.count) * 60.0 / Double(rules.readingWordsPerMinute)).rounded(.up)),
            speakingSeconds: Int((Double(words.count) * 60.0 / Double(rules.speakingWordsPerMinute)).rounded(.up)),
            readability: readability,
            readabilityLabel: readability.map(Self.readabilityLabel),
            score: score
        )
    }

    private static let smileys: Set<UInt32> = [0x1F60A, 0x1F642, 0x1F604, 0x1F600, 0x1F603, 0x1F601, 0x2764, 0x1F44D, 0x1F389, 0x1F60D, 0x1F970]

    /// Vowel groups, less a silent final "e": "make" 1, "table" 2, "readability" 5.
    static func syllables(_ word: String) -> Int {
        var groups = 0
        var inGroup = false
        for c in word {
            let vowel = "aeiouy".contains(c)
            if vowel, !inGroup { groups += 1 }
            inGroup = vowel
        }
        if groups > 1, word.hasSuffix("e"), !word.hasSuffix("le"), !word.hasSuffix("ee") { groups -= 1 }
        return max(groups, 1)
    }

    static func readabilityLabel(_ score: Int) -> String {
        switch score {
        case 90...: "Very easy to read"
        case 80...: "Easy to read"
        case 70...: "Fairly easy to read"
        case 60...: "Plain English"
        case 50...: "Fairly hard to read"
        case 30...: "Hard to read"
        default: "Very hard to read"
        }
    }

    private static func words(in text: String) -> Set<String> {
        Set(WritingText.tokenize(text).filter(\.isWord).map(\.key))
    }

    /// `suggestions` found for `old`, carried over to `new`: those wholly
    /// before or after the one changed region shift with it; any the edit
    /// touched are dropped, as is one whose word the edit runs into.
    static func rebase(_ suggestions: [WritingSuggestion], old: String, new: String) -> [WritingSuggestion] {
        if old == new { return suggestions }
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var prefix = 0
        let shorter = min(a.count, b.count)
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldEnd = a.count - suffix
        let delta = b.count - a.count
        func wordChar(_ index: Int) -> Bool {
            guard index >= 0, index < b.count, let scalar = Unicode.Scalar(b[index]) else { return false }
            return WritingText.isLetterOrDigit(scalar)
        }
        return suggestions.compactMap { s in
            let before = s.end < prefix || (s.end == prefix && s.start < s.end && !wordChar(prefix))
            let after = s.start > oldEnd || (s.start == oldEnd && s.start < s.end && !wordChar(oldEnd + delta - 1))
            if before { return s }
            if after {
                var moved = s
                moved.start += delta
                moved.end += delta
                moved.markStart += delta
                moved.markEnd += delta
                return moved
            }
            return nil
        }
    }

    /// `text` with `suggestion` applied, or nil when that span no longer says what was checked.
    static func apply(_ text: String, _ suggestion: WritingSuggestion) -> String? {
        guard let replacement = suggestion.replacement, suggestion.end <= text.utf16Length,
              text.utf16Slice(suggestion.start, suggestion.end) == suggestion.original
        else { return nil }
        return text.utf16Slice(0, suggestion.start) + replacement + text.utf16Slice(suggestion.end, text.utf16Length)
    }
}
