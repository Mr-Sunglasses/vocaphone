import Foundation

/// The grammar model's output as suggestions: a word diff of each sentence
/// against what the model made of it, each changed run classified into a kind
/// with a reason. Mirrors ModelEdits.kt.
struct ModelEdits {
    let rules: WritingRules

    struct Hunk: Equatable {
        let aFrom: Int
        let aTo: Int
        let bFrom: Int
        let bTo: Int
    }

    func suggestions(
        _ text: String, _ tokens: [WritingToken], _ sentence: WritingSentence, corrected: String
    ) -> [WritingSuggestion] {
        let a = Array(tokens[sentence.first...sentence.last])
        let b = WritingText.tokenize(corrected)
        if a.map(\.text) == b.map(\.text) { return [] }
        var out: [WritingSuggestion] = []
        for hunk in hunks(a, b) {
            let inserted = hunk.bTo > hunk.bFrom ? corrected.utf16Slice(b[hunk.bFrom].start, b[hunk.bTo - 1].end) : ""
            let from = sentence.first + hunk.aFrom
            let to = sentence.first + hunk.aTo
            let edit = WritingEdits.build(tokens, floor: sentence.first, from: from, to: to, inserted: inserted)
            let removed = Array(a[hunk.aFrom..<hunk.aTo])
            let added = Array(b[hunk.bFrom..<hunk.bTo])
            let previous = hunk.aFrom > 0 ? a[hunk.aFrom - 1] : nil
            let next = hunk.aTo < a.count ? a[hunk.aTo] : nil
            let atStart = hunk.aFrom == 0 || WritingText.isSentenceStart(tokens, sentence, from)
            let (kind, messageKey) = classify(
                removed, added, previous: previous, next: next, atStart: atStart, endOfSentence: hunk.aFrom == a.count
            )
            let k = rules.kind(kind)
            let original = text.utf16Slice(edit.start, edit.end)
            let shownOriginal = edit.shownOriginal(text)
            let shownReplacement = edit.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let values = [
                "original": shownOriginal,
                "replacement": shownReplacement,
                "previous": previous?.text ?? "",
                "next": next?.text ?? "",
                "subject": previous.flatMap { $0.hasLetter ? $0.text : nil } ?? "",
                "original_gloss": rules.glosses[WritingToken.normalize(shownOriginal)] ?? "",
                "replacement_gloss": rules.glosses[WritingToken.normalize(shownReplacement)] ?? "",
            ]
            let template = messageKey.flatMap { rules.messages[$0] } ?? k.message
            out.append(WritingSuggestion(
                start: edit.start, end: edit.end, original: original, replacement: edit.replacement,
                markStart: edit.markStart, markEnd: edit.markEnd, kind: k.id, category: k.category, title: k.title,
                message: WritingEdits.format(template, values), mechanical: k.mechanical, source: .model, rule: nil
            ))
        }
        return out
    }

    /// The kind and, where one fits better than the kind's own, a message key.
    func classify(
        _ removed: [WritingToken], _ added: [WritingToken],
        previous: WritingToken?, next: WritingToken?, atStart: Bool, endOfSentence: Bool
    ) -> (String, String?) {
        let all = removed + added
        if !all.isEmpty, !all.contains(where: \.isWord) {
            let key: String? = if removed.isEmpty, added.count == 1 {
                switch added[0].text {
                case ",": "punctuation.add_comma"
                case "?": "punctuation.add_question"
                case ".": endOfSentence ? "punctuation.add_period" : "punctuation.add_other"
                default: "punctuation.add_other"
                }
            } else if removed.isEmpty {
                "punctuation.add_other"
            } else if added.isEmpty {
                "punctuation.remove"
            } else if added.count == 1, added[0].text == "?" {
                "punctuation.add_question"
            } else {
                nil
            }
            return ("punctuation", key)
        }
        if removed.count == added.count, !removed.isEmpty, zip(removed, added).allSatisfy({ $0.key == $1.key }) {
            if removed.contains(where: { $0.key == "i" || $0.key.hasPrefix("i'") }) {
                return ("capitalization", "capitalization.i")
            }
            return ("capitalization", atStart ? "capitalization.start" : nil)
        }
        if removed.count == 1, added.count == 1, removed[0].isWord, added[0].isWord {
            return classifyWord(removed[0].key, added[0].key, previous)
        }
        if removed.isEmpty {
            let word = added.count == 1 ? added[0].key : nil
            if let word, rules.articles.contains(word) { return ("article", "article.missing") }
            if let word, rules.classes["be"]?.contains(word) == true || Self.helpers.contains(word) {
                return ("missing_word", "missing_word.verb")
            }
            return ("missing_word", nil)
        }
        if added.isEmpty {
            let word = removed.count == 1 ? removed[0].key : nil
            if let word, previous?.key == word { return ("repeated_word", nil) }
            if let word, rules.articles.contains(word) { return ("article", "article.extra") }
            return ("extra_word", "extra_word.remove")
        }
        let joinedA = removed.map(\.key).joined().unicodeScalars.filter(WritingText.isLetterOrDigit)
        let joinedB = added.map(\.key).joined().unicodeScalars.filter(WritingText.isLetterOrDigit)
        if String(String.UnicodeScalarView(joinedA)) == String(String.UnicodeScalarView(joinedB)) {
            return ("spelling", nil)
        }
        return ("word_choice", nil)
    }

    private func classifyWord(_ o: String, _ r: String, _ previous: WritingToken?) -> (String, String?) {
        if rules.confusable(o, r) {
            let glossed = rules.glosses[o] != nil && rules.glosses[r] != nil
            return ("confused_words", glossed ? "confused_words.gloss" : nil)
        }
        if o.replacingOccurrences(of: "'", with: "") == r.replacingOccurrences(of: "'", with: ""),
           r.contains("'"), !o.contains("'") {
            return ("apostrophe", nil)
        }
        if rules.articles.contains(o), rules.articles.contains(r) {
            if o == "a", r == "an" { return ("article", "article.a_to_an") }
            if o == "an", r == "a" { return ("article", "article.an_to_a") }
            return ("article", nil)
        }
        let pronouns = rules.subjectPronouns.union(rules.objectPronouns)
        if pronouns.contains(o), pronouns.contains(r) {
            if rules.subjectPronouns.contains(r), rules.objectPronouns.contains(o) { return ("pronoun", "pronoun.subject") }
            if rules.objectPronouns.contains(r), rules.subjectPronouns.contains(o) { return ("pronoun", "pronoun.object") }
            return ("pronoun", nil)
        }
        if rules.prepositions.contains(o), rules.prepositions.contains(r) { return ("preposition", nil) }
        if Self.agreement.contains(where: { $0.contains(o) && $0.contains(r) }) { return agreement(previous) }
        let verbs = rules.verbs
        if let lemma = verbs.lemma(o), lemma == verbs.lemma(r) {
            return o == verbs.third(r) || r == verbs.third(o) ? agreement(previous) : ("verb_form", nil)
        }
        if Self.plural(o) == r || Self.plural(r) == o {
            // "two dog" is a noun; "the dogs barks" is a verb that disagrees with "dogs".
            let noun = previous == nil || previous?.hasLetter != true
                || rules.determiners.contains(previous!.key) || rules.prepositions.contains(previous!.key)
            return noun ? ("noun_number", nil) : agreement(previous)
        }
        if min(o.count, r.count) >= 3, Self.editDistance(o, r) <= 2 { return ("spelling", nil) }
        return ("word_choice", nil)
    }

    private func agreement(_ previous: WritingToken?) -> (String, String?) {
        if let previous, previous.hasLetter, !rules.determiners.contains(previous.key) {
            return ("agreement", "agreement.subject")
        }
        return ("agreement", nil)
    }

    private static func plural(_ word: String) -> String {
        let chars = Array(word)
        if word.hasSuffix("y"), chars.count > 1, !"aeiou".contains(chars[chars.count - 2]) {
            return String(word.dropLast(1)) + "ies"
        }
        if word.hasSuffix("s") || word.hasSuffix("x") || word.hasSuffix("ch") || word.hasSuffix("sh") {
            return word + "es"
        }
        return word + "s"
    }

    /// The changed runs, compared without case so a capital is its own
    /// suggestion, and a run of one-for-one swaps split into one per word.
    private func hunks(_ a: [WritingToken], _ b: [WritingToken]) -> [Hunk] {
        var out: [Hunk] = []
        var i = 0
        var j = 0
        func caseOnly(_ toI: Int, _ toJ: Int) {
            while i < toI, j < toJ {
                if a[i].text != b[j].text { out.append(Hunk(aFrom: i, aTo: i + 1, bFrom: j, bTo: j + 1)) }
                i += 1
                j += 1
            }
        }
        for h in Self.diff(a.map(\.key), b.map(\.key)) {
            caseOnly(h.aFrom, h.bFrom)
            let width = h.aTo - h.aFrom
            if width == h.bTo - h.bFrom, width > 1 {
                for k in 0..<width {
                    out.append(Hunk(aFrom: h.aFrom + k, aTo: h.aFrom + k + 1, bFrom: h.bFrom + k, bTo: h.bFrom + k + 1))
                }
            } else {
                out.append(h)
            }
            i = h.aTo
            j = h.bTo
        }
        caseOnly(a.count, b.count)
        return out
    }

    private static let helpers: Set<String> = ["have", "has", "had", "do", "does", "did", "will", "would", "can", "could", "should"]
    private static let agreement: [Set<String>] = [
        ["is", "are", "am", "was", "were"], ["has", "have"], ["does", "do"], ["doesn't", "don't"],
        ["isn't", "aren't"], ["wasn't", "weren't"], ["hasn't", "haven't"],
    ]

    /// The most the longest-common-subsequence table may hold; past it, the
    /// changed middle is one hunk. As `MAX_DIFF_CELLS` in Kotlin.
    static let maxDiffCells = 500_000

    /// The changed runs between `a` and `b`, by longest common subsequence of
    /// what is left once the shared start and end are set aside. Ties go to
    /// deleting from `a` first, on both platforms. A middle too long to compare
    /// in `maxDiffCells` comes back as one replaced run.
    static func diff(_ a: [String], _ b: [String]) -> [Hunk] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let n = a.count - prefix - suffix
        let m = b.count - prefix - suffix
        if n == 0, m == 0 { return [] }
        if n == 0 || m == 0 || n * m > maxDiffCells {
            return [Hunk(aFrom: prefix, aTo: prefix + n, bFrom: prefix, bTo: prefix + m)]
        }
        // lcs[i * (m + 1) + j]: the common subsequence of the middles from i and j on.
        let width = m + 1
        var lcs = [Int](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * width + j] = a[prefix + i] == b[prefix + j]
                    ? lcs[(i + 1) * width + j + 1] + 1
                    : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }
        var hunks: [Hunk] = []
        var i = 0
        var j = 0
        var open: (Int, Int)?
        func close() {
            if let (ai, bj) = open { hunks.append(Hunk(aFrom: prefix + ai, aTo: prefix + i, bFrom: prefix + bj, bTo: prefix + j)) }
            open = nil
        }
        while i < n || j < m {
            if i < n, j < m, a[prefix + i] == b[prefix + j] {
                close()
                i += 1
                j += 1
            } else if j >= m || (i < n && lcs[(i + 1) * width + j] >= lcs[i * width + j + 1]) {
                if open == nil { open = (i, j) }
                i += 1
            } else {
                if open == nil { open = (i, j) }
                j += 1
            }
        }
        close()
        return hunks
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a)
        let y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var current = Array(repeating: 0, count: y.count + 1)
            current[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }
}
