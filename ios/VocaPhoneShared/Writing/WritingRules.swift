import Foundation

/// Grammarly's four groups: red, blue, green, purple.
enum WritingCategory: String, CaseIterable, Codable, Sendable {
    case correctness, clarity, engagement, delivery

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// `assets/keyboard/writing-rules.json`, parsed: the kinds of suggestion and
/// their messages, the word tables, the rules and the tone lexicon. Parsing
/// costs a few milliseconds, so callers build one off the main thread and keep
/// it. Mirrors android/.../writing/WritingRules.kt.
final class WritingRules: @unchecked Sendable {
    struct Kind: Sendable {
        let id: String
        let category: WritingCategory
        let title: String
        let mechanical: Bool
        let message: String
    }

    struct Tone: Sendable {
        let id: String
        let label: String
        let emoji: String
        let words: Set<String>
        let phrases: [String]
    }

    struct Failure: Error {}

    let kinds: [String: Kind]
    let messages: [String: String]
    let glosses: [String: String]
    private let confusionSet: [String: Int]
    let subjectPronouns: Set<String>
    let objectPronouns: Set<String>
    let articles: Set<String>
    let prepositions: Set<String>
    let determiners: Set<String>
    let stopwords: Set<String>
    let verbs: Verbs
    let classes: [String: Set<String>]
    let rules: [WritingRule]
    /// Rule indices by the word their pattern starts with, so a token is tried against only those.
    let rulesByFirstWord: [String: [Int]]
    /// Rule indices whose pattern starts with a class: tried at every token.
    let rulesStartingWithClass: [Int]
    let tones: [Tone]
    let toneMinimumCharacters: Int
    let toneMinimumScore: Int
    let readingWordsPerMinute: Int
    let speakingWordsPerMinute: Int
    let longSentenceWords: Int
    let overusedWordCount: Int
    let scoreWeights: [WritingCategory: Double]
    let scoreMinimumWords: Int

    /// The copy bundled with the app or the keyboard.
    static func bundled(_ bundle: Bundle = .main) -> WritingRules? {
        guard let url = bundle.url(forResource: "writing-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? WritingRules(data: data)
    }

    init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure() }
        func object(_ key: String) throws -> [String: Any] {
            guard let value = json[key] as? [String: Any] else { throw Failure() }
            return value
        }
        func strings(_ value: Any?) -> [String] { (value as? [String]) ?? [] }

        var kinds: [String: Kind] = [:]
        for (id, value) in try object("kinds") {
            guard let k = value as? [String: Any] else { throw Failure() }
            kinds[id] = Kind(
                id: id,
                category: WritingCategory(rawValue: k["category"] as? String ?? "") ?? .correctness,
                title: k["title"] as? String ?? id,
                mechanical: k["mechanical"] as? Bool ?? false,
                message: k["message"] as? String ?? ""
            )
        }
        self.kinds = kinds
        messages = (try object("messages") as? [String: String]) ?? [:]
        glosses = (try object("glosses") as? [String: String]) ?? [:]
        var confusion: [String: Int] = [:]
        for (i, set) in ((json["confusions"] as? [[String]]) ?? []).enumerated() {
            for word in set { confusion[word] = i }
        }
        confusionSet = confusion
        let pronouns = try object("pronouns")
        subjectPronouns = Set(strings(pronouns["subject"]))
        objectPronouns = Set(strings(pronouns["object"]))
        articles = Set(strings(json["articles"]))
        prepositions = Set(strings(json["prepositions"]))
        determiners = Set(strings(json["determiners"]))
        stopwords = Set(strings(json["stopwords"]))
        let irregular = ((json["irregularVerbs"] as? [[Any]]) ?? []).map { row in row.map { $0 as? String } }
        verbs = Verbs(regular: strings(json["verbs"]), irregular: irregular)
        var classes: [String: Set<String>] = [:]
        for (name, value) in try object("classes") {
            classes[name] = Set(strings(value).map(WritingToken.normalize))
        }
        self.classes = classes
        rules = try ((json["rules"] as? [[String: Any]]) ?? []).map(WritingRule.compile)
        var byWord: [String: [Int]] = [:]
        var byClass: [Int] = []
        for (i, rule) in rules.enumerated() {
            if let words = rule.firstWords {
                for word in words { byWord[word, default: []].append(i) }
            } else {
                byClass.append(i)
            }
        }
        rulesByFirstWord = byWord
        rulesStartingWithClass = byClass
        let tone = try object("tone")
        toneMinimumCharacters = tone["minimumCharacters"] as? Int ?? 90
        toneMinimumScore = tone["minimumScore"] as? Int ?? 4
        tones = ((tone["tones"] as? [[String: Any]]) ?? []).map { o in
            Tone(
                id: o["id"] as? String ?? "",
                label: o["label"] as? String ?? "",
                emoji: o["emoji"] as? String ?? "",
                words: Set(strings(o["words"])),
                phrases: strings(o["phrases"])
            )
        }
        let readability = try object("readability")
        readingWordsPerMinute = readability["wordsPerMinuteReading"] as? Int ?? 238
        speakingWordsPerMinute = readability["wordsPerMinuteSpeaking"] as? Int ?? 150
        longSentenceWords = readability["longSentenceWords"] as? Int ?? 40
        overusedWordCount = readability["overusedWordCount"] as? Int ?? 3
        let score = try object("score")
        let weights = score["weights"] as? [String: Any] ?? [:]
        var scoreWeights: [WritingCategory: Double] = [:]
        for category in WritingCategory.allCases {
            scoreWeights[category] = (weights[category.rawValue] as? NSNumber)?.doubleValue ?? 1
        }
        self.scoreWeights = scoreWeights
        scoreMinimumWords = score["minimumWords"] as? Int ?? 50
    }

    func kind(_ id: String) -> Kind { kinds[id] ?? kinds["word_choice"]! }

    /// Whether `a` and `b` are in one confusion set ("their", "there", "they're").
    func confusable(_ a: String, _ b: String) -> Bool {
        guard let x = confusionSet[a] else { return false }
        return x == confusionSet[b]
    }
}

/// Verb forms from a list of regular verbs and a table of irregular ones,
/// enough to tell "sings" from "sing" and to write "seeing" from "see".
/// Mirrors `Verbs` in WritingRules.kt.
final class Verbs: @unchecked Sendable {
    private var bases = Set<String>()
    private var irregularBase: [String: String] = [:]
    private var irregularPast: [String: String] = [:]
    private var irregularParticiple: [String: String] = [:]
    private var irregularThird: [String: String] = [:]
    private var irregularIng: [String: String] = [:]
    private var participles = Set<String>()
    private var pastOnly = Set<String>()

    init(regular: [String], irregular: [[String?]]) {
        bases.formUnion(regular)
        for row in irregular { if let base = row.first ?? nil { bases.insert(base) } }
        for row in irregular {
            guard row.count >= 3, let base = row[0], let past = row[1], let participle = row[2] else { continue }
            irregularPast[base] = past
            irregularParticiple[base] = participle
            let third = row.count > 3 ? row[3] : nil
            let ing = row.count > 4 ? row[4] : nil
            if let third { irregularThird[base] = third }
            if let ing { irregularIng[base] = ing }
            for form in [past, participle, third, ing].compactMap({ $0 })
            where !bases.contains(form) && irregularBase[form] == nil {
                irregularBase[form] = base
            }
            participles.insert(participle)
            if past != participle, !bases.contains(past) { pastOnly.insert(past) }
        }
    }

    func isBase(_ word: String) -> Bool { bases.contains(word) }

    /// The base form of `word`, or nil when it is no verb this knows.
    func lemma(_ word: String) -> String? {
        if bases.contains(word) { return word }
        if let base = irregularBase[word] { return base }
        // A candidate counts only if the verb's own forms produce the word.
        return candidates(word).first { base in
            bases.contains(base)
                && (third(base) == word || past(base) == word || participle(base) == word || ing(base) == word)
        }
    }

    private func candidates(_ word: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) { if s.count >= 2 { out.append(s) } }
        let chars = Array(word)
        if word.hasSuffix("ies") {
            add(String(word.dropLast(3)) + "y")
        } else if word.hasSuffix("es") {
            add(String(word.dropLast(2)))
            add(String(word.dropLast(1)))
        } else if word.hasSuffix("s"), !word.hasSuffix("ss") {
            add(String(word.dropLast(1)))
        }
        if word.hasSuffix("ied") {
            add(String(word.dropLast(3)) + "y")
        } else if word.hasSuffix("ed") {
            add(String(word.dropLast(2)))
            add(String(word.dropLast(1)))
            if chars.count > 4, chars[chars.count - 3] == chars[chars.count - 4] { add(String(word.dropLast(3))) }
        }
        if word.hasSuffix("ing") {
            let stem = String(word.dropLast(3))
            let s = Array(stem)
            if stem.hasSuffix("y") { add(String(stem.dropLast(1)) + "ie") }
            add(stem)
            add(stem + "e")
            if s.count > 2, s[s.count - 1] == s[s.count - 2] { add(String(stem.dropLast(1))) }
        }
        return out
    }

    func third(_ base: String) -> String {
        if let form = irregularThird[base] { return form }
        let chars = Array(base)
        if base.hasSuffix("y"), chars.count > 1, !Self.vowels.contains(chars[chars.count - 2]) {
            return String(base.dropLast(1)) + "ies"
        }
        if base.hasSuffix("s") || base.hasSuffix("x") || base.hasSuffix("z") || base.hasSuffix("ch")
            || base.hasSuffix("sh") || base.hasSuffix("o") {
            return base + "es"
        }
        return base + "s"
    }

    func past(_ base: String) -> String {
        if let form = irregularPast[base] { return form }
        let chars = Array(base)
        if base.hasSuffix("e") { return base + "d" }
        if base.hasSuffix("y"), chars.count > 1, !Self.vowels.contains(chars[chars.count - 2]) {
            return String(base.dropLast(1)) + "ied"
        }
        if doubles(base), let last = base.last { return base + String(last) + "ed" }
        return base + "ed"
    }

    func participle(_ base: String) -> String { irregularParticiple[base] ?? past(base) }

    func ing(_ base: String) -> String {
        if let form = irregularIng[base] { return form }
        if base.hasSuffix("ie") { return String(base.dropLast(2)) + "ying" }
        if base.hasSuffix("e"), !base.hasSuffix("ee"), !base.hasSuffix("ye"), !base.hasSuffix("oe") {
            return String(base.dropLast(1)) + "ing"
        }
        if doubles(base), let last = base.last { return base + String(last) + "ing" }
        return base + "ing"
    }

    /// An irregular past that is not also the participle or a base: "went", "ate", "knew".
    func isSimplePastOnly(_ word: String) -> Bool { pastOnly.contains(word) }

    /// A past participle: an irregular one, or "-ed" on a known regular verb.
    func isParticiple(_ word: String) -> Bool {
        if participles.contains(word) { return true }
        guard let base = lemma(word) else { return false }
        return irregularParticiple[base] == nil && word == past(base) && word != base
    }

    /// One vowel group, ending consonant–vowel–consonant: "stop" → "stopped", but "visit" → "visited".
    private func doubles(_ base: String) -> Bool {
        let chars = Array(base)
        guard chars.count >= 3 else { return false }
        let a = chars[chars.count - 3]
        let b = chars[chars.count - 2]
        let c = chars[chars.count - 1]
        if "wxy".contains(c) || Self.vowels.contains(c) || !Self.vowels.contains(b) || Self.vowels.contains(a) {
            return false
        }
        var groups = 0
        var inGroup = false
        for ch in chars {
            let vowel = Self.vowels.contains(ch)
            if vowel, !inGroup { groups += 1 }
            inGroup = vowel
        }
        return groups == 1
    }

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
}
