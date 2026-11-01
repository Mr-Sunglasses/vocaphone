import Foundation

/// One line of `writing-rules.json`, compiled. The pattern language is
/// described beside `WritingRule.kt`, which this mirrors.
struct WritingRule: Sendable {
    enum Element: Sendable {
        case words(Set<String>)
        case wordClass(String)
    }

    let id: String
    private let elements: [Element]
    private let atStart: Bool
    private let atEnd: Bool
    private let notAtStart: Bool
    /// The word right before the match must be one of these, or the match must start the sentence.
    private let after: Set<String>?
    /// The word right before the match must not be one of these.
    private let notAfter: Set<String>
    /// No word after the match, to the end of the sentence, may be one of these.
    private let unlessLater: Set<String>
    let replace: String?
    let kind: String
    let message: String?
    /// The option that turns this rule on (`WritingCheck.Options.optIn`); nil runs always.
    let optIn: String?

    static func compile(_ o: [String: Any]) throws -> WritingRule {
        guard let match = o["match"] as? String, let id = o["id"] as? String, let kind = o["kind"] as? String else {
            throw WritingRules.Failure()
        }
        var raw = match.split(separator: " ").map(String.init)
        let atStart = raw.first == "^"
        let atEnd = raw.last == "$"
        if atStart { raw.removeFirst() }
        if atEnd { raw.removeLast() }
        var elements: [Element] = []
        for part in raw {
            if part.hasPrefix("{"), part.hasSuffix("}") {
                elements.append(.wordClass(String(part.dropFirst().dropLast())))
            } else if part.contains("|") {
                elements.append(.words(Set(part.split(separator: "|").map { WritingToken.normalize(String($0)) })))
            } else {
                for token in WritingText.tokenize(part) { elements.append(.words([token.key])) }
            }
        }
        return WritingRule(
            id: id,
            elements: elements,
            atStart: atStart,
            atEnd: atEnd,
            notAtStart: o["notAtStart"] as? Bool ?? false,
            after: (o["after"] as? [String]).map { Set($0.map(WritingToken.normalize)) },
            notAfter: Set((o["notAfter"] as? [String] ?? []).map(WritingToken.normalize)),
            unlessLater: Set((o["unlessLater"] as? [String] ?? []).map(WritingToken.normalize)),
            replace: o["replace"] as? String,
            kind: kind,
            message: o["message"] as? String,
            optIn: o["optIn"] as? String
        )
    }

    /// The words the pattern can start with, or nil when it starts with a class.
    var firstWords: Set<String>? {
        if case let .words(options) = elements.first { return options }
        return nil
    }

    /// How many tokens match from `index`, or 0. `start`: whether `index` opens the sentence.
    func match(
        _ tokens: [WritingToken], _ sentence: WritingSentence, _ index: Int, _ rules: WritingRules, start: Bool
    ) -> Int {
        if atStart, !start { return 0 }
        if notAtStart, start { return 0 }
        let before = index > sentence.first ? tokens[index - 1] : nil
        if let before, notAfter.contains(before.key) { return 0 }
        if let after, !start, !(before.map { after.contains($0.key) } ?? false) { return 0 }
        if let before, Self.hyphens.contains(before.text), before.end == tokens[index].start { return 0 }
        var i = index
        for element in elements {
            if i > sentence.last { return 0 }
            let token = tokens[i]
            let previous = i > index ? tokens[i - 1] : nil
            let ok = switch element {
            case let .words(options): options.contains(token.key)
            case let .wordClass(name): matchesClass(name, token, previous, rules)
            }
            if !ok { return 0 }
            i += 1
        }
        if i <= sentence.last, Self.hyphens.contains(tokens[i].text), tokens[i - 1].end == tokens[i].start { return 0 }
        if atEnd, i <= sentence.last, tokens[i...sentence.last].contains(where: \.isWord) { return 0 }
        if !unlessLater.isEmpty, i <= sentence.last, tokens[i...sentence.last].contains(where: { unlessLater.contains($0.key) }) {
            return 0
        }
        return i - index
    }

    private func matchesClass(_ name: String, _ token: WritingToken, _ previous: WritingToken?, _ rules: WritingRules) -> Bool {
        guard token.isWord else { return false }
        let key = token.key
        switch name {
        case "word":
            return token.hasLetter
        case "same":
            guard token.hasLetter, let previous, previous.key == key else { return false }
            return !(rules.classes["allowed_double"]?.contains(key) ?? false)
        case "name":
            return token.text.unicodeScalars.count >= 2 && WritingText.isUppercase(token.text)
                && !Self.pronounI.contains(key)
                && token.text.unicodeScalars.allSatisfy { WritingText.isLetter($0) || $0 == "'" || $0 == "’" }
        case "number":
            return key.unicodeScalars.allSatisfy { $0 >= "0" && $0 <= "9" }
        case "clock_time":
            return Self.isClockTime(key)
        case "verb_base":
            return rules.verbs.isBase(key)
        case "verb_inflected":
            guard let lemma = rules.verbs.lemma(key) else { return false }
            return lemma != key
        case "verb_ing":
            guard key.hasSuffix("ing"), let lemma = rules.verbs.lemma(key) else { return false }
            return lemma != key
        case "simple_past":
            return rules.verbs.isSimplePastOnly(key)
        case "participle":
            return rules.verbs.isParticiple(key)
        default:
            return rules.classes[name]?.contains(key) ?? false
        }
    }

    /// The replacement for `matched` tokens, or nil for an information-only rule.
    func expand(_ matched: [WritingToken], _ rules: WritingRules) -> String? {
        guard let template = replace else { return nil }
        let parts = template.split(separator: " ").map(String.init).map { part -> String in
            guard let (fn, n) = Self.reference(part), n >= 1, n <= matched.count else { return part }
            let token = matched[n - 1]
            return fn.isEmpty ? token.text : apply(fn, token.key, rules)
        }
        return WritingText.join(parts)
    }

    /// `$n` or `${fn:n}`.
    private static func reference(_ part: String) -> (String, Int)? {
        guard part.hasPrefix("$") else { return nil }
        var body = part.dropFirst()
        if body.hasPrefix("{"), body.hasSuffix("}") {
            body = body.dropFirst().dropLast()
            let pieces = body.split(separator: ":")
            guard pieces.count == 2, let n = Int(pieces[1]) else { return nil }
            return (String(pieces[0]), n)
        }
        guard let n = Int(body) else { return nil }
        return ("", n)
    }

    private func apply(_ fn: String, _ word: String, _ rules: WritingRules) -> String {
        let verbs = rules.verbs
        switch fn {
        case "base": return verbs.lemma(word) ?? word
        case "ing": return verbs.ing(verbs.lemma(word) ?? word)
        case "participle": return verbs.participle(verbs.lemma(word) ?? word)
        case "past": return verbs.past(verbs.lemma(word) ?? word)
        case "third": return verbs.third(verbs.lemma(word) ?? word)
        case "any": return Self.any[word] ?? word
        case "subject": return Self.subject[word] ?? word
        case "capital": return word.prefix(1).uppercased() + word.dropFirst()
        default: return word
        }
    }

    private static let hyphens: Set<String> = ["-", "‐", "‑"]
    private static let pronounI: Set<String> = ["i", "i'm", "i've", "i'll", "i'd"]
    private static let any = ["nothing": "anything", "nobody": "anybody", "nowhere": "anywhere", "none": "any", "no": "any"]
    private static let subject = [
        "me": "I", "him": "he", "her": "she", "us": "we", "them": "they",
        // A contraction's subject: "I'm agree" → "I agree".
        "i'm": "I", "im": "I", "we're": "we", "they're": "they", "you're": "you", "he's": "he", "she's": "she",
    ]

    /// "3pm", "11am": a time typed as one word.
    private static func isClockTime(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 3 || scalars.count == 4 else { return false }
        let digits = scalars.dropLast(2)
        let suffix = String(String.UnicodeScalarView(scalars.suffix(2)))
        return digits.allSatisfy { $0 >= "0" && $0 <= "9" } && (suffix == "am" || suffix == "pm")
    }
}
