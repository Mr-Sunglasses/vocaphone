import Foundation

/// The checks that need to know which word is a verb's subject: "The kids
/// plays", "My sister live", "Each of the boys have", "Where is my keys",
/// "I go to the gym yesterday". A port of `WritingAgreement.kt`, which says
/// how; both are tested against `assets/grammar/writing_fixtures.json`.
struct WritingAgreement: Sendable {
    let rules: WritingRules
    let tagger: PosTagger
    let spelling: WritingSpelling?

    private enum Number { case singular, plural, first }

    /// The subject's head word, its number, and how a message names it ("mom and dad").
    private struct Subject {
        let head: Int
        let number: Number
        let label: String
    }

    /// The tokens of one sentence with their tags.
    private struct Tagged {
        let tokens: [WritingToken]
        let sentence: WritingSentence
        let tags: [String]

        func tag(_ i: Int) -> String { tags[i - sentence.first] }
        func key(_ i: Int) -> String { tokens[i].key }
        func inside(_ i: Int) -> Bool { i >= sentence.first && i <= sentence.last }
    }

    func suggestions(
        _ text: String, _ tokens: [WritingToken], _ sentence: WritingSentence, _ protected: [NSRange],
        _ keep: Set<String>, _ fixed: [WritingSuggestion]
    ) -> [WritingSuggestion] {
        let s = Tagged(
            tokens: tokens, sentence: sentence,
            tags: tagger.tag((sentence.first...sentence.last).map { tokens[$0].text })
        )
        func free(_ i: Int) -> Bool {
            let t = tokens[i]
            return !keep.contains(t.key)
                && !protected.contains(where: { t.start < $0.location + $0.length && $0.location < t.end })
                && !fixed.contains(where: { $0.start < t.end && t.start < $0.end })
        }
        var out: [WritingSuggestion] = []
        for v in sentence.first...sentence.last {
            guard tokens[v].isWord, free(v), let verb = verbNumber(s, v) else { continue }
            let there = inverted(s, v)
            guard let subject = there ?? self.subject(s, v), free(subject.head) else { continue }
            let replacement: String?
            if subject.number == verb {
                replacement = nil
            } else if subject.number == .first {
                replacement = toFirst(s, v)
            } else if subject.number == .singular {
                replacement = verb == .plural ? toSingular(s, v) : nil
            } else {
                replacement = verb == .singular ? toPlural(s, v) : nil
            }
            guard let replacement else { continue }
            out.append(suggestion(
                text, s, v, replacement, kind: "agreement",
                message: rules.messages["agreement.subject"] ?? rules.kind("agreement").message,
                values: ["subject": subject.label],
                rule: there != nil ? "agreement-there" : "agreement-subject"
            ))
        }
        if let past = pastTime(text, s, free) { out.append(past) }
        return out
    }

    // MARK: - The verb

    private func verbNumber(_ s: Tagged, _ v: Int) -> Number? {
        let key = s.key(v)
        let tag = s.tag(v)
        guard tag.hasPrefix("VB"), tag != "VB", tag != "VBN", tag != "VBG" else { return nil }
        if key == "am" { return .first }
        if Self.singularForms.contains(key) { return .singular }
        if Self.pluralForms.contains(key) { return .plural }
        if tag == "VBZ", key.hasSuffix("s") { return .singular }
        if tag == "VBP" { return .plural }
        return nil
    }

    private func toSingular(_ s: Tagged, _ v: Int) -> String? {
        let key = s.key(v)
        if let form = Self.singularOf[key] { return form }
        guard s.tag(v) == "VBP", isVerbBase(key) else { return nil }
        return rules.verbs.third(key)
    }

    private func toPlural(_ s: Tagged, _ v: Int) -> String? {
        let key = s.key(v)
        if let form = Self.pluralOf[key] { return form }
        guard s.tag(v) == "VBZ" else { return nil }
        return baseOf(key)
    }

    private func toFirst(_ s: Tagged, _ v: Int) -> String? {
        let key = s.key(v)
        if let form = Self.firstOf[key] { return form }
        guard s.tag(v) == "VBZ" else { return nil }
        return baseOf(key)
    }

    private func isVerbBase(_ word: String) -> Bool {
        if rules.verbs.isBase(word) { return true }
        guard let spelling else { return false }
        return spelling.isKnown(word) && spelling.isKnown(rules.verbs.third(word))
    }

    private func baseOf(_ third: String) -> String? {
        if let lemma = rules.verbs.lemma(third), lemma != third { return lemma }
        guard let spelling else { return nil }
        let candidates: [String]
        if third.hasSuffix("ies") {
            candidates = [String(third.dropLast(3)) + "y"]
        } else if third.hasSuffix("es") {
            candidates = [String(third.dropLast(2)), String(third.dropLast(1))]
        } else if third.hasSuffix("s"), !third.hasSuffix("ss") {
            candidates = [String(third.dropLast(1))]
        } else {
            candidates = []
        }
        return candidates.first { $0.utf16.count >= 2 && spelling.isKnown($0) && rules.verbs.third($0) == third }
    }

    // MARK: - The subject

    private func subject(_ s: Tagged, _ v: Int) -> Subject? {
        var j = v - 1
        var skipped = 0
        while s.inside(j), Self.adverbTags.contains(s.tag(j)), !Self.thereHere.contains(s.key(j)), skipped < 2 {
            j -= 1
            skipped += 1
        }
        guard s.inside(j), nounish(s, j) else { return nil }
        var head = j
        var label = s.tokens[j].text
        var number = headNumber(s, j)
        var start = phraseStart(s, j)
        var hops = 0
        while true {
            if s.inside(start - 2), s.key(start - 1) == "and", s.tag(start - 1) == "CC", nounish(s, start - 2) {
                let left = phraseStart(s, start - 2)
                if Self.eachEvery.contains(s.key(left)) { return nil }
                number = .plural
                label = s.tokens[start - 2].text + " and " + label
                start = left
            }
            let preposition = start - 1
            guard s.inside(preposition - 1), Self.ppPrepositions.contains(s.key(preposition)), hops < 3 else { break }
            let left = preposition - 1
            guard nounish(s, left) else { return nil }
            if !(s.key(preposition) == "of" && Self.fromObject.contains(s.key(left))) {
                number = headNumber(s, left)
                head = left
                label = s.tokens[left].text
            }
            start = phraseStart(s, left)
            hops += 1
        }
        guard let number, opensClause(s, start) else { return nil }
        return Subject(head: head, number: number, label: label)
    }

    private func inverted(_ s: Tagged, _ v: Int) -> Subject? {
        guard s.key(v) == "is" || s.key(v) == "was" else { return nil }
        let before = v - 1
        guard s.inside(before), Self.thereHereWhere.contains(s.key(before)) else { return nil }
        guard WritingText.isSentenceStart(s.tokens, s.sentence, before) || opensClause(s, before) else { return nil }
        var k = v + 1
        while s.inside(k), Self.nounModifierTags.contains(s.tag(k)) || Self.adverbTags.contains(s.tag(k)) {
            if Self.singularDeterminers.contains(s.key(k)) { return nil }
            k += 1
        }
        guard s.inside(k), Self.pluralNounTags.contains(s.tag(k)), !Self.singularS.contains(s.key(k)),
              !Self.unsureS.contains(s.key(k))
        else { return nil }
        return Subject(head: k, number: .plural, label: s.tokens[k].text)
    }

    private func nounish(_ s: Tagged, _ i: Int) -> Bool {
        let tag = s.tag(i)
        let key = s.key(i)
        return Self.nounTags.contains(tag) || Self.pronounNumber[key] != nil || Self.singularWords.contains(key)
            || Self.pluralWords.contains(key) || Self.fromObject.contains(key)
            || (tag == "CD" && key.contains(where: \.isLetter))
    }

    private func headNumber(_ s: Tagged, _ i: Int) -> Number? {
        let key = s.key(i)
        if key.contains("'"), !s.tag(i).hasSuffix("+POS") { return nil }
        if let number = Self.pronounNumber[key] { return number }
        if Self.objectPronouns.contains(key) { return nil }
        if Self.singularWords.contains(key) { return .singular }
        if Self.pluralWords.contains(key) { return .plural }
        if Self.fromObject.contains(key) || Self.unsure.contains(key) { return nil }
        switch s.tag(i) {
        case "CD":
            return key == "one" ? .singular : .plural
        case "NNS", "NNPS":
            if Self.singularS.contains(key) { return .singular }
            if Self.unsureS.contains(key) { return nil }
            if Self.units.contains(key), s.inside(i - 1), Self.amountTags.contains(s.tag(i - 1)) { return nil }
            return .plural
        case "NN":
            if key.hasSuffix("s"), !key.hasSuffix("ss"), !key.hasSuffix("us"), !key.hasSuffix("is") { return nil }
            return .singular
        case "NNP":
            return key.hasSuffix("s") ? nil : .singular
        default:
            return nil
        }
    }

    private func phraseStart(_ s: Tagged, _ head: Int) -> Int {
        var i = head
        while s.inside(i - 1), Self.nounModifierTags.contains(s.tag(i - 1)), !Self.stopPhrase.contains(s.key(i - 1)) {
            i -= 1
        }
        return i
    }

    private func opensClause(_ s: Tagged, _ start: Int) -> Bool {
        if WritingText.isSentenceStart(s.tokens, s.sentence, start) { return true }
        let p = start - 1
        let key = s.key(p)
        if Self.clausePunctuation.contains(s.tokens[p].text) { return true }
        if s.tag(p) == "CC" { return true }
        if Self.subordinators.contains(key) || Self.clauseVerbs.contains(key) { return true }
        return WritingText.isSentenceStart(s.tokens, s.sentence, p) && Self.openingTags.contains(s.tag(p))
    }

    // MARK: - A time in the past, said in the present

    private func pastTime(_ text: String, _ s: Tagged, _ free: (Int) -> Bool) -> WritingSuggestion? {
        var last = s.sentence.last
        while s.inside(last), !s.tokens[last].isWord { last -= 1 }
        guard s.inside(last) else { return nil }
        let marker: Int
        if s.key(last) == "yesterday" || s.key(last) == "ago" {
            marker = 1
        } else if s.inside(last - 1), s.key(last - 1) == "last", Self.pastUnits.contains(s.key(last)) {
            marker = 2
        } else {
            return nil
        }
        let markerStart = last - marker + 1
        if (s.sentence.first..<markerStart).contains(where: { Self.notSimplePast.contains(s.key($0)) }) { return nil }
        let verbs = (s.sentence.first..<markerStart).filter { verbNumber(s, $0) != nil }
        guard verbs.count == 1, let v = verbs.first, free(v) else { return nil }
        let key = s.key(v)
        if Self.perfectAuxiliaries.contains(key), s.inside(v + 1), s.tag(v + 1) == "VBN" || s.key(v + 1) == "been" {
            return nil
        }
        guard subject(s, v) != nil else { return nil }
        let past: String?
        if let form = Self.pastOf[key] {
            past = form
        } else if s.tag(v) == "VBP" {
            past = isVerbBase(key) ? rules.verbs.past(key) : nil
        } else if s.tag(v) == "VBZ" {
            past = baseOf(key).map { rules.verbs.past($0) }
        } else {
            past = nil
        }
        guard let past, past != key else { return nil }
        let phrase = (markerStart...last).map { s.tokens[$0].text }.joined(separator: " ")
        return suggestion(
            text, s, v, past, kind: "verb_form",
            message: "“{marker}” is in the past, so use “{replacement}”.",
            values: ["marker": phrase],
            rule: "tense-past-time"
        )
    }

    private func suggestion(
        _ text: String, _ s: Tagged, _ v: Int, _ replacement: String, kind: String, message: String,
        values: [String: String], rule: String
    ) -> WritingSuggestion {
        let k = rules.kind(kind)
        let typed = s.tokens[v].text
        let capital = typed.unicodeScalars.first.map { ("A"..."Z").contains($0) } ?? false
        let shown = capital ? replacement.prefix(1).uppercased() + replacement.dropFirst() : replacement
        let edit = WritingEdits.build(s.tokens, floor: s.sentence.first, from: v, to: v + 1, inserted: shown)
        var all = values
        all["original"] = typed
        all["replacement"] = shown
        return WritingSuggestion(
            start: edit.start, end: edit.end, original: text.utf16Slice(edit.start, edit.end),
            replacement: edit.replacement, markStart: edit.markStart, markEnd: edit.markEnd,
            kind: k.id, category: k.category, title: k.title,
            message: WritingEdits.format(message, all), mechanical: k.mechanical, source: .rule, rule: rule
        )
    }

    // MARK: - Tables (as in WritingAgreement.kt)

    private static let adverbTags: Set<String> = ["RB", "RBR", "RBS"]
    private static let nounTags: Set<String> = ["NN", "NNS", "NNP", "NNPS", "PRP"]
    private static let pluralNounTags: Set<String> = ["NNS", "NNPS"]
    private static let amountTags: Set<String> = ["CD", "$", "DT"]
    private static let units: Set<String> = [
        "dollars", "bucks", "cents", "euros", "pounds", "pence", "rupees", "yen", "miles", "kilometers",
        "kilometres", "km", "meters", "metres", "feet", "inches", "yards", "hours", "minutes", "seconds",
        "days", "weeks", "months", "years", "percent", "kilos", "kilograms", "grams", "liters", "litres", "gallons",
    ]
    private static let nounModifierTags: Set<String> = [
        "DT", "PDT", "PRP$", "JJ", "JJR", "JJS", "CD", "NN", "NNP", "HYPH",
        "NN+POS", "NNP+POS", "NNS+POS", "NNPS+POS",
    ]
    private static let openingTags: Set<String> = ["RB", "NN", "NNP", "UH"]
    private static let clausePunctuation: Set<String> = [",", ";", ":", "—", "–"]
    private static let thereHere: Set<String> = ["there", "here"]
    private static let thereHereWhere: Set<String> = ["there", "here", "where"]
    private static let stopPhrase: Set<String> = ["and", "or", "but", "nor", "than"]
    private static let singularDeterminers: Set<String> = ["a", "an", "one", "each", "every", "this", "that", "another"]
    private static let singularForms: Set<String> = ["is", "was", "has", "does", "doesn't", "isn't", "wasn't", "hasn't"]
    private static let pluralForms: Set<String> = ["are", "were", "have", "do", "don't", "aren't", "weren't", "haven't"]
    private static let singularOf = [
        "are": "is", "were": "was", "have": "has", "do": "does",
        "don't": "doesn't", "aren't": "isn't", "weren't": "wasn't", "haven't": "hasn't",
    ]
    private static let pluralOf = [
        "is": "are", "was": "were", "has": "have", "does": "do",
        "doesn't": "don't", "isn't": "aren't", "wasn't": "weren't", "hasn't": "haven't",
    ]
    private static let firstOf: [String: String?] = [
        "is": "am", "has": "have", "does": "do", "doesn't": "don't", "hasn't": "haven't",
        "are": "am", "isn't": nil, "aren't": nil, "were": nil, "weren't": nil, "was": nil,
        "wasn't": nil, "have": nil, "do": nil, "don't": nil, "haven't": nil,
    ]
    private static let pastOf = [
        "am": "was", "is": "was", "are": "were", "has": "had", "have": "had", "do": "did", "does": "did",
        "don't": "didn't", "doesn't": "didn't", "isn't": "wasn't", "aren't": "weren't",
        "was": "was", "were": "were", "wasn't": "wasn't", "weren't": "weren't",
    ]
    private static let pronounNumber: [String: Number] = [
        "i": .first, "you": .plural, "we": .plural, "they": .plural, "he": .singular, "she": .singular, "it": .singular,
    ]
    private static let objectPronouns: Set<String> = ["me", "him", "her", "us", "them"]
    private static let singularWords: Set<String> = [
        "everyone", "everybody", "someone", "somebody", "anyone", "anybody", "nobody", "everything",
        "something", "anything", "nothing", "each", "one", "either", "neither", "another", "this", "that",
    ]
    private static let pluralWords: Set<String> = ["these", "those", "both", "few", "many", "several", "people", "police"]
    private static let fromObject: Set<String> = [
        "all", "some", "most", "none", "half", "any", "lot", "lots", "plenty", "rest", "majority", "part", "percent",
    ]
    private static let eachEvery: Set<String> = ["each", "every"]
    private static let unsure: Set<String> = [
        "team", "staff", "family", "group", "government", "company", "crew", "audience", "committee", "couple",
        "class", "band", "data", "media", "number", "total", "pair", "jury", "public",
        "management", "board", "faculty", "army", "personnel", "who", "which", "what", "that",
    ]
    private static let singularS: Set<String> = [
        "news", "physics", "mathematics", "maths", "economics", "athletics", "ethics", "gymnastics",
        "linguistics", "measles", "diabetes", "electronics", "genetics", "aerobics",
    ]
    private static let unsureS: Set<String> = [
        "series", "species", "means", "headquarters", "politics", "statistics", "crossroads", "whereabouts",
        "thanks", "glasses", "pants", "scissors",
    ]
    private static let ppPrepositions: Set<String> = [
        "of", "in", "on", "at", "with", "for", "from", "near", "behind", "by", "about", "under", "over",
        "between", "among", "without", "inside", "outside", "around", "like", "across", "beside",
    ]
    private static let subordinators: Set<String> = [
        "because", "if", "when", "whenever", "although", "though", "while", "since", "unless", "until",
        "after", "before", "once", "that", "so", "whether", "cause", "cuz", "coz",
    ]
    private static let clauseVerbs: Set<String> = [
        "think", "thought", "know", "knew", "guess", "hope", "believe", "say", "said", "says", "feel", "felt",
        "mean", "heard", "hear", "see", "saw", "bet", "swear", "noticed", "notice", "realize", "realized",
        "realise", "realised", "figure", "suppose", "reckon", "wish",
    ]
    private static let pastUnits: Set<String> = [
        "night", "week", "month", "year", "weekend", "summer", "winter", "spring", "fall", "autumn", "time",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]
    private static let notSimplePast: Set<String> = [
        "since", "will", "won't", "every", "usually", "always", "often", "sometimes", "until", "if",
    ]
    private static let perfectAuxiliaries: Set<String> = ["have", "has"]
}
