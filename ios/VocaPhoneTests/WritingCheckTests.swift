import Foundation
import Testing

/// `assets/grammar/writing_fixtures.json`, which WritingCheckTest.kt reads
/// too, so both keyboards and both apps flag the same words the same way.
struct WritingCheckTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("assets")
    static let rules: WritingRules = try! WritingRules(
        data: Data(contentsOf: root.appendingPathComponent("keyboard/writing-rules.json"))
    )
    nonisolated(unsafe) static let document: [String: Any] = try! JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("grammar/writing_fixtures.json"))
    ) as! [String: Any]

    static func cases(_ name: String) -> [[String: Any]] { document[name] as? [[String: Any]] ?? [] }

    /// JSON with sorted keys, so a parsed expectation and a computed value compare by content.
    static func canonical(_ value: Any?) -> String {
        let wrapped: Any = [value ?? NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    static func label(_ c: [String: Any], _ key: String) -> Comment {
        let name = c["name"] as? String ?? c["text"] as? String ?? c["word"] as? String ?? "?"
        return "\(name) · \(key)"
    }

    static func model(_ c: [String: Any]) -> WritingCheck.Model? {
        guard let map = c["model"] as? [String: Any] else { return nil }
        return { sentence in
            guard let value = map[sentence] else { return sentence }
            return value as? String
        }
    }

    static func options(_ c: [String: Any]) -> WritingCheck.Options {
        var options = WritingCheck.Options()
        guard let o = c["options"] as? [String: Any] else { return options }
        if let categories = o["categories"] as? [String] {
            options.categories = Set(categories.compactMap(WritingCategory.init(rawValue:)))
        }
        if let keep = o["keep"] as? [String] { options.keep = Set(keep) }
        if let typed = o["typed"] as? Bool { options.typed = typed }
        return options
    }

    static func json(_ s: WritingSuggestion) -> [String: Any] {
        [
            "start": s.start, "end": s.end, "original": s.original,
            "replacement": s.replacement.map { $0 as Any } ?? NSNull(),
            "mark": [s.markStart, s.markEnd], "kind": s.kind, "category": s.category.rawValue,
            "label": s.label, "message": s.message, "source": s.source.rawValue,
            "rule": s.rule.map { $0 as Any } ?? NSNull(),
        ]
    }

    static func bare(_ text: String, _ start: Int, _ end: Int) -> WritingSuggestion {
        WritingSuggestion(
            start: start, end: end, original: text.utf16Slice(start, end), replacement: "x",
            markStart: start, markEnd: end, kind: "spelling", category: .correctness, title: "Spelling",
            message: "", mechanical: true, source: .model, rule: nil
        )
    }

    @Test func everyRuleCompilesAndNamesAKnownKind() {
        for rule in Self.rules.rules { #expect(Self.rules.kinds[rule.kind] != nil, "\(rule.id)") }
        #expect(Set(Self.rules.rules.map(\.id)).count == Self.rules.rules.count)
    }

    @Test func tokenize() {
        for c in Self.cases("tokenize") {
            let tokens = WritingText.tokenize(c["text"] as! String).map { [$0.text, $0.start, $0.end, $0.isWord] as [Any] }
            #expect(Self.canonical(tokens) == Self.canonical(c["tokens"]), Self.label(c, "tokens"))
        }
    }

    @Test func sentences() {
        for c in Self.cases("sentences") {
            let text = c["text"] as! String
            let s = WritingText.sentences(text, WritingText.tokenize(text)).map { [$0.start, $0.end, $0.paragraph] }
            #expect(Self.canonical(s) == Self.canonical(c["sentences"]), Self.label(c, "sentences"))
        }
    }

    @Test func verbs() {
        let verbs = Self.rules.verbs
        for c in Self.cases("verbs") {
            let word = c["word"] as! String
            let lemma = verbs.lemma(word)
            #expect(Self.canonical(lemma) == Self.canonical(c["lemma"]), Self.label(c, "lemma"))
            let forms: Any = lemma.map { [verbs.third($0), verbs.past($0), verbs.participle($0), verbs.ing($0)] } ?? NSNull()
            #expect(Self.canonical(forms) == Self.canonical(c["forms"]), Self.label(c, "forms"))
            #expect(Self.canonical(verbs.isParticiple(word)) == Self.canonical(c["participle"]), Self.label(c, "participle"))
        }
    }

    @Test func syllables() {
        for c in Self.cases("syllables") {
            #expect(WritingCheck.syllables(c["word"] as! String) == c["count"] as? Int, Self.label(c, "count"))
        }
    }

    @Test func checks() {
        let check = WritingCheck(rules: Self.rules)
        for c in Self.cases("check") {
            let report = check.check(c["text"] as! String, model: Self.model(c), options: Self.options(c))
            #expect(Self.canonical(report.suggestions.map(Self.json)) == Self.canonical(c["suggestions"]), Self.label(c, "suggestions"))
            #expect(Self.canonical(report.tones.map(\.id)) == Self.canonical(c["tones"]), Self.label(c, "tones"))
            let s = report.stats
            let stats: [Any] = [
                s.words, s.characters, s.sentences, s.readingSeconds, s.speakingSeconds,
                s.readability.map { $0 as Any } ?? NSNull(), s.score.map { $0 as Any } ?? NSNull(),
            ]
            #expect(Self.canonical(stats) == Self.canonical(c["stats"]), Self.label(c, "stats"))
            #expect(report.modelPending == (c["modelPending"] as? Bool), Self.label(c, "modelPending"))
        }
    }

    @Test func rebase() {
        for c in Self.cases("rebase") {
            let old = c["old"] as! String
            let spans = (c["spans"] as! [[Int]]).map { Self.bare(old, $0[0], $0[1]) }
            let rebased = WritingCheck.rebase(spans, old: old, new: c["new"] as! String).map { [$0.start, $0.end] }
            #expect(Self.canonical(rebased) == Self.canonical(c["expected"]), Self.label(c, "expected"))
        }
    }

    @Test func apply() {
        for c in Self.cases("apply") {
            let text = c["text"] as! String
            var s = Self.bare(text, c["start"] as! Int, c["end"] as! Int)
            s.original = c["original"] as! String
            s.replacement = c["replacement"] as? String
            #expect(Self.canonical(WritingCheck.apply(text, s)) == Self.canonical(c["expected"]), Self.label(c, "expected"))
        }
    }

    /// Every suggestion accepted, last first: the spacing `WritingEdits.build` leaves behind.
    @Test func accept() {
        let check = WritingCheck(rules: Self.rules)
        for c in Self.cases("accept") {
            var text = c["text"] as! String
            let report = check.check(text, model: Self.model(c), options: Self.options(c))
            for s in report.suggestions.filter(\.isActionable).sorted(by: { $0.start > $1.start }) {
                text = WritingCheck.apply(text, s) ?? text
            }
            #expect(Self.canonical(text) == Self.canonical(c["expected"]), Self.label(c, "expected"))
        }
    }

    @Test func diffSetsTheSharedEndsAsideAndBoundsTheMiddle() {
        let words = (0..<3000).map { "w\($0)" }
        var one = words
        one[1500] = "x"
        #expect(ModelEdits.diff(words, one) == [ModelEdits.Hunk(aFrom: 1500, aTo: 1501, bFrom: 1500, bTo: 1501)])
        // A middle past the table's budget is one replaced run, not a 2000 × 2000 table.
        let a = ["same"] + (0..<2000).map { "a\($0)" } + ["same"]
        let b = ["same"] + (0..<2000).map { "b\($0)" } + ["same"]
        #expect(ModelEdits.diff(a, b) == [ModelEdits.Hunk(aFrom: 1, aTo: 2001, bFrom: 1, bTo: 2001)])
        // A short middle still aligns word by word.
        #expect(ModelEdits.diff(["a", "b", "c", "d"], ["a", "c", "x", "d"]) == [
            ModelEdits.Hunk(aFrom: 1, aTo: 2, bFrom: 1, bTo: 1), ModelEdits.Hunk(aFrom: 3, aTo: 3, bFrom: 2, bTo: 3),
        ])
    }
}

/// The rules' false-positive gate, as WritingCleanTextTest.kt: at most 2% of
/// `tools/grammar-eval/clean_en.jsonl` may get a correctness suggestion.
struct WritingCleanTextTests {
    static func lines(_ name: String) -> [[String: String]] {
        let url = WritingCheckTests.root.deletingLastPathComponent().appendingPathComponent("tools/grammar-eval/\(name)")
        return (try! String(contentsOf: url, encoding: .utf8)).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
        }
    }

    @Test func correctTextGetsAlmostNoCorrectnessSuggestions() {
        let check = WritingCheck(rules: WritingCheckTests.rules)
        let cases = Self.lines("clean_en.jsonl")
        let flagged = cases.filter { c in
            check.check(c["input"]!).suggestions.contains { $0.category == .correctness }
        }
        #expect(Double(flagged.count) / Double(cases.count) <= 0.02, "\(flagged.map { $0["input"]! })")
    }

    /// Every rule fix applied to the chat set must move a line toward what was meant, never away.
    @Test func ruleFixesOnTypedTextNeverMakeALineWorse() {
        let check = WritingCheck(rules: WritingCheckTests.rules)
        let cases = Self.lines("typed_en.jsonl")
        #expect(!cases.isEmpty)
        var options = WritingCheck.Options()
        options.categories = [.correctness]
        let worse = cases.compactMap { c -> String? in
            let input = c["input"]!
            let expected = c["expected"]!
            var text = input
            for s in check.check(input, options: options).suggestions.reversed() {
                text = WritingCheck.apply(text, s) ?? text
            }
            return Self.distance(text, expected) > Self.distance(input, expected) ? "\(input) → \(text) (expected \(expected))" : nil
        }
        #expect(worse.isEmpty, "\(worse.count) lines made worse:\n\(worse.joined(separator: "\n"))")
    }

    /// Word-level edit distance over Writing check's own tokens.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = WritingText.tokenize(a).map(\.text)
        let y = WritingText.tokenize(b).map(\.text)
        var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in stride(from: 1, through: x.count, by: 1) {
            for j in stride(from: 1, through: y.count, by: 1) {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
        }
        return d[x.count][y.count]
    }
}
