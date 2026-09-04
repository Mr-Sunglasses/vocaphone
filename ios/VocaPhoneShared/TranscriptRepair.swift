import Foundation

/// Turns what a speech model heard into what the speaker meant to write:
/// hesitation sounds dropped, false starts collapsed, and the punctuation the
/// model left out put in.
///
/// This is deliberately **not** part of ``TranscriptStyler``. That stage
/// documents a contract it has to keep — no style adds, removes, or substitutes
/// a word — and this stage exists precisely to break it, under a switch of its
/// own. Keeping them apart is what lets the styles still be described honestly.
///
/// Everything here is rule-based. There is no model, no network call, and no
/// language understanding: the rules are the conservative subset where a
/// mistake is nearly impossible to make, and anything needing judgement about
/// what the speaker meant is left alone on purpose. The order of the stages is
/// load-bearing and is documented at each one.
///
/// Mirrors the Android client's `TranscriptRepair`; the two are expected to
/// produce the same text for the same transcript.
enum TranscriptRepair {

    // MARK: - Entry point

    /// - Parameters:
    ///   - text: a transcript that has already been through ``TranscriptSanitizer``.
    ///   - language: the language the finished text is written in, or `"auto"`.
    static func apply(_ text: String?, language: String = "auto") -> String {
        let source = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "" }

        let punctuation = SentencePunctuation.resolve(language: language, text: source)
        let code = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
        let spans = ProtectedSpans.mask(source)

        var working = spans.text
        // 1. Fillers first: they are the noise every later rule would otherwise
        //    have to reason around. "we should um we should ship" is not a
        //    stutter until the "um" between the copies is gone.
        working = removeFillers(working, code: code)
        // 2. Stutters, on the text the fillers left behind.
        working = collapseStutters(working, punctuation: punctuation)
        // 3. Normalize the marks that are there before inferring the ones that
        //    are not, so inference counts real sentence boundaries.
        working = repairMarks(working, punctuation: punctuation)
        // 4. Inference is written against how English builds a sentence. In a
        //    script that spaces or terminates differently it would do damage,
        //    and in another Latin language its trigger words simply never match.
        if punctuation.usesLatinLayout {
            working = infer(working, punctuation: punctuation)
        }

        let repaired = spans.restore(working)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A transcript that repaired down to nothing is a rule misfiring, not a
        // silent recording — the sanitizer has already had its say about those.
        // Hand back what came in rather than an empty text field.
        return repaired.contains(where: { $0.isLetter || $0.isNumber }) ? repaired : source
    }

    // MARK: - Words

    /// A whitespace-delimited chunk split into the punctuation around it and the
    /// word inside, so a rule can drop a word without losing the comma that was
    /// attached to it, or match a word without its full stop getting in the way.
    private struct Word {
        var leading: String
        var text: String
        var trailing: String

        var isEmpty: Bool { leading.isEmpty && text.isEmpty && trailing.isEmpty }
        var rendered: String { leading + text + trailing }

        /// Lowercased letters and digits only. Apostrophes go, so `don't` and
        /// `dont` match, and the placeholder scalars stay so a masked URL can
        /// never compare equal to a bare number.
        var key: String {
            text.lowercased().filter {
                $0.isLetter || $0.isNumber
                    || $0 == ProtectedSpans.open || $0 == ProtectedSpans.close
            }
        }

        var isProtected: Bool { text.contains(ProtectedSpans.open) }

        var startsUppercase: Bool {
            text.first(where: \.isLetter)?.isUppercase ?? false
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character == "'" || character == "’" || character == "-"
            || character == ProtectedSpans.open || character == ProtectedSpans.close
    }

    private static func split(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).map { chunk in
            let characters = Array(chunk)
            var start = 0
            while start < characters.count, !isWordCharacter(characters[start]) { start += 1 }
            var end = characters.count
            while end > start, !isWordCharacter(characters[end - 1]) { end -= 1 }
            return Word(
                leading: String(characters[0..<start]),
                text: String(characters[start..<end]),
                trailing: String(characters[end...])
            )
        }
    }

    private static func joined(_ words: [Word]) -> String {
        words.filter { !$0.isEmpty }.map(\.rendered).joined(separator: " ")
    }

    // MARK: - Fillers

    /// Hesitation sounds that are not a word in any language this app
    /// transcribes, so they can go whatever was spoken.
    ///
    /// Every one is non-lexical: there is no sentence in which it carries
    /// meaning, which is the whole reason removing it is safe. That is also why
    /// `like`, `you know`, `I mean` and `actually` are **not** here. Each is a
    /// real word often enough that dropping it needs judgement about what the
    /// speaker meant, and this stage does not have any.
    private static let alwaysSafeFillers: Set<String> = ["uh", "uhm", "umh", "erm", "hm"]

    /// English hesitation sounds that are ordinary words somewhere else.
    ///
    /// `um` is German for "at" — "um acht Uhr" — and `er` is German for "he"
    /// and Dutch for "there". Dropping them from a German transcript deletes
    /// content, so they go only when the transcript is English, or when
    /// Automatic was selected and ``looksEnglish(_:)`` recognizes the sentence
    /// around them.
    private static let englishFillers: Set<String> = ["um", "er"]

    /// Sounds that mean *yes* or *no*, and must survive. `mhm` and `uh-huh` are
    /// answers to a question, and a transcript that drops them says the opposite
    /// of what was said. They are listed rather than merely absent so that
    /// widening the filler sets cannot quietly swallow one.
    private static let affirmations: Set<String> = [
        "mhm", "mhmm", "mmhm", "uhuh", "uhhuh", "nuhuh", "huh", "hu",
    ]

    /// Words that reach a filler spelling only because ``canonical(_:)``
    /// flattens repeated letters, and so have to be caught before it runs.
    /// "Err on the side of caution" is the verb; a model writing a hesitation
    /// as `err` rather than `uh` is rare enough that keeping the word wins.
    private static let literalExceptions: Set<String> = ["err"]

    /// How many markers a transcript needs before Automatic will treat it as
    /// English.
    ///
    /// One is not enough. A German sentence only has to brush against a single
    /// English-looking word to lose its "er", and "er kommt her" did exactly
    /// that. Two independent markers is a far higher bar for an accident to
    /// clear, and English prose of any length clears it easily.
    private static let englishMarkersNeeded = 2

    /// High-frequency English words that are **not** also words in the other
    /// Latin-script languages this app transcribes. That exclusion is the whole
    /// point of the list, so it is much shorter than a frequency table would
    /// be: `is` is Dutch, `was` and `will` are German, `for` is Danish, `of` is
    /// Dutch for "or", `i` is Danish for "in", `her` is German for "hither",
    /// `over` is Dutch, `want` is Dutch for "because", and `come` is Italian
    /// for "how". Any of those would call a foreign sentence English and cost
    /// it a word.
    private static let englishMarkers: Set<String> = [
        "the", "and", "you", "your", "yours", "with", "that", "thats", "this",
        "these", "those", "what", "whats", "which", "when", "where", "who",
        "how", "have", "has", "had", "are", "were", "been", "being",
        "not", "dont", "doesnt", "didnt", "isnt", "arent", "cant", "wont",
        "wouldnt", "couldnt", "shouldnt", "havent", "hasnt",
        "it", "its", "they", "them", "their", "theyre", "theres", "wheres",
        "she", "his", "there", "would", "could", "should", "about", "because",
        "know", "knew", "think", "thought", "going", "please", "thanks",
        "very", "again", "only", "some", "than", "then", "through",
        "need", "make", "made", "take", "took", "from", "more", "most",
        "much", "many", "something", "anything", "everything", "nothing",
        "yeah", "gonna", "wanna", "gotta", "ive", "youre", "youve",
        "today", "tomorrow", "yesterday", "here", "there", "everyone",
        "people", "thing", "things", "time", "good", "great", "sure",
        "right", "wrong", "back", "down", "off", "got", "getting",
        "said", "told", "asked", "does", "did", "doing", "actually",
        "probably", "really", "always", "never", "maybe",
    ]

    /// Only the non-lexical hesitation sounds, same bar as ``universalFillers``.
    /// A language is absent here because nobody has checked it, not because it
    /// has no fillers.
    private static let localFillers: [String: Set<String>] = [
        "de": ["äh", "ähm", "öh", "öhm"],
        "nl": ["eh", "ehm", "uh"],
        "fr": ["euh", "heu"],
        "es": ["eh", "em"],
        "it": ["ehm", "eh"],
    ]

    /// Fillers in the scripts that are written without spaces, where there are
    /// no words to walk. Removed as plain substrings, which is only safe because
    /// each of these is written with a length mark that a content word does not
    /// carry.
    private static let unspacedFillers: [String: [String]] = [
        "ja": ["えーと", "えっと", "ええと", "あのー", "あのう"],
        "zh": ["呃"],
        "yue": ["呃"],
    ]

    /// Collapses a run of one repeated letter, so however long the model drew
    /// the sound out it lands on the same key: `ummmm` and `uhhh` become `um`
    /// and `uh`. `uh-huh` arrives with its hyphen already gone — ``Word/key``
    /// keeps only letters and digits — and so reaches ``affirmations`` intact.
    private static func canonical(_ key: String) -> String {
        var result = ""
        var previous: Character?
        for character in key {
            if character != previous { result.append(character) }
            previous = character
        }
        return result
    }

    /// Letters that belong to another Latin alphabet. A transcript carrying one
    /// is not English whatever else it contains, and this is the cheapest hard
    /// veto available before counting anything.
    private static let foreignLetters = "äöüßåæøœçñõãêôîûàèìòùáéíóúýðþğışłżźćęą"

    /// Whether the English filler set applies.
    ///
    /// An explicit `en` always qualifies, and so does a language the engine
    /// detected as English. On Automatic nothing has said what the language is,
    /// so the sentence has to say it itself — twice over, and without a letter
    /// from another alphabet in it.
    ///
    /// The cost is a filler left in a short English fragment that carries fewer
    /// than two markers. That is the right direction to be wrong in: leaving an
    /// "um" is a blemish, and deleting the subject of a German sentence is not.
    private static func looksEnglish(_ code: String, words: [Word]) -> Bool {
        if code == "en" { return true }
        guard code.isEmpty || code == "auto" else { return false }
        var seen = Set<String>()
        for word in words {
            if word.text.lowercased().contains(where: { foreignLetters.contains($0) }) {
                return false
            }
            if englishMarkers.contains(word.key) { seen.insert(word.key) }
        }
        return seen.count >= englishMarkersNeeded
    }

    private static func isFiller(_ word: Word, code: String, english: Bool) -> Bool {
        guard !word.isProtected else { return false }
        // A quoted filler is being talked about rather than said: someone
        // dictating `he said "um" a lot` means the word to be there.
        guard !word.leading.contains(where: isQuote),
              !word.trailing.contains(where: isQuote)
        else { return false }
        let raw = word.key
        guard !raw.isEmpty, !literalExceptions.contains(raw) else { return false }
        let key = canonical(raw)
        guard !affirmations.contains(key) else { return false }
        if alwaysSafeFillers.contains(key) { return true }
        if english, englishFillers.contains(key) { return true }
        return localFillers[code]?.contains(key) == true
    }

    private static func isQuote(_ character: Character) -> Bool {
        "\"'“”‘’«»„".contains(character)
    }

    private static func removeFillers(_ text: String, code: String) -> String {
        var result = text
        for filler in unspacedFillers[code] ?? [] {
            result = result.replacingOccurrences(of: filler, with: "")
        }

        let words = split(result)
        let english = looksEnglish(code, words: words)
        var kept: [Word] = []
        for word in words {
            guard isFiller(word, code: code, english: english) else {
                kept.append(word)
                continue
            }
            // The filler goes, but a sentence it happened to end does not:
            // "I was thinking. Um. We should ship" keeps both full stops.
            let terminators = word.trailing.filter { "!?.。！？।۔".contains($0) }
            if !terminators.isEmpty, var previous = kept.last {
                if !previous.trailing.contains(where: { terminators.contains($0) }) {
                    previous.trailing += terminators
                    kept[kept.count - 1] = previous
                }
            } else if word.trailing.contains(","), var previous = kept.last,
                      previous.trailing.hasSuffix(",") {
                // A filler set off by commas on both sides takes both with it:
                // "I think, um, we should" is "I think we should", not
                // "I think, we should".
                previous.trailing.removeLast()
                kept[kept.count - 1] = previous
            }
        }
        return joined(kept)
    }

    // MARK: - Stutters

    /// Words whose immediate repeat is a stutter and essentially never
    /// grammar: determiners, prepositions, conjunctions and subject pronouns. A
    /// repeated content word ("very very") is emphasis the speaker meant, and
    /// is not here.
    ///
    /// Deliberately narrower than "closed class". A copula, an auxiliary or a
    /// possessive or a modal doubles legitimately far too often to guess at —
    /// "what it is is a problem", "the things I have have value", "I gave her
    /// her coat", "I can can peaches", "there, there" — so none of those are
    /// here either. The cost of leaving a real stutter in is a duplicated word;
    /// the cost of being wrong is a deleted one.
    private static let functionWords: Set<String> = [
        "the", "a", "an", "and", "but", "or", "to", "of", "in", "on", "at",
        "for", "with", "from", "by", "as", "if", "than",
        "i", "you", "we", "they", "he", "she", "it", "this", "these", "those",
        "what", "when", "where", "why", "who", "how",
    ]

    /// Doubles that are ordinary English even though the word is on the list
    /// above. "The thing that that man said" is correct, and looks exactly like
    /// a stutter to a rule that only compares two words.
    private static let legitimateDoubles: Set<String> = ["that"]

    /// Longest false start collapsed. Beyond this it is a repeated sentence,
    /// which ``TranscriptSanitizer`` already has thresholds for.
    private static let maximumStutterWords = 4

    /// Collapses a phrase said twice in a row — "we should we should probably".
    ///
    /// Only an immediate repeat, and only the second copy is kept, because it is
    /// the copy the speaker carried on from: "we should, we should probably
    /// ship" has the comma on the abandoned half and the sentence on the other.
    ///
    /// A multi-word repeat also has to be followed by something. That is what
    /// separates a false start from a phrase said twice on purpose: the speaker
    /// who restarts goes on to finish the sentence, where "I love you I love
    /// you" and "no no no no" end where they end.
    private static func collapseStutters(
        _ text: String,
        punctuation: SentencePunctuation
    ) -> String {
        let words = split(text)
        guard words.count >= 2 else { return text }

        var result: [Word] = []
        var index = 0
        while index < words.count {
            var collapsed = false
            // Longest first, so "we should we should" is one phrase twice over
            // rather than two separate doubled words.
            for length in stride(from: min(maximumStutterWords, (words.count - index) / 2), through: 1, by: -1)
            where matchesRepeat(words, at: index, length: length, punctuation: punctuation) {
                if let leading = words[index].leading.isEmpty ? nil : words[index].leading,
                   words[index + length].leading.isEmpty {
                    var carried = words[index + length]
                    carried.leading = leading
                    result.append(carried)
                    result.append(contentsOf: words[(index + length + 1)..<(index + length * 2)])
                } else {
                    result.append(contentsOf: words[(index + length)..<(index + length * 2)])
                }
                index += length * 2
                collapsed = true
                break
            }
            if !collapsed {
                result.append(words[index])
                index += 1
            }
        }
        return joined(result)
    }

    private static func matchesRepeat(
        _ words: [Word],
        at index: Int,
        length: Int,
        punctuation: SentencePunctuation
    ) -> Bool {
        guard index + length * 2 <= words.count else { return false }
        // A repeat with nothing after it was said twice on purpose. A false
        // start is the beginning of a sentence the speaker then finishes.
        if length > 1, index + length * 2 >= words.count { return false }
        // Neither is a repeat containing ``SpokenEmoji``'s trigger. Nobody
        // abandons a sentence on the one word this app treats as a command, so
        // "crying emoji crying emoji crying emoji" is three emoji — and unlike
        // the guard above, those copies *are* followed by more of themselves.
        //
        // Anywhere in the unit, not just the end, because this walk advances a
        // word at a time and re-enters the middle of a run it declined: three
        // "crying emoji" read from index one are two "emoji crying", and that
        // rotation puts the trigger first.
        if length > 1,
           (0..<length).contains(where: { SpokenEmoji.triggerWords.contains(words[index + $0].key) })
        {
            return false
        }
        for offset in 0..<length {
            let first = words[index + offset]
            let second = words[index + length + offset]
            guard !first.isProtected, !first.key.isEmpty, first.key == second.key else { return false }
            // A sentence ended between the copies, so the second one starts a
            // new thought: "I went home. Home is quiet."
            if ends(first, punctuation: punctuation) { return false }
        }
        if length == 1 {
            let key = words[index].key
            guard functionWords.contains(key), !legitimateDoubles.contains(key) else { return false }
        }
        return true
    }

    private static func ends(_ word: Word, punctuation: SentencePunctuation) -> Bool {
        word.trailing.contains { punctuation.terminators.contains($0) }
    }

    // MARK: - Marks that are already there

    /// Normalizes the punctuation the model emitted: spacing around it, runs of
    /// it, and pairs of marks that cannot both be right. Nothing here decides
    /// where a sentence ends; it only tidies the decisions already made.
    private static func repairMarks(
        _ text: String,
        punctuation: SentencePunctuation
    ) -> String {
        var result = replacing("\\s+", with: " ", in: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Built from the shared sets rather than a literal per rule, so the
        // Kotlin port cannot quietly cover a different set of scripts.
        let marks = "[" + SentencePunctuation.universalMarks + "]"
        let terminators = "[" + SentencePunctuation.universalTerminators + "]"
        let separators = "[" + SentencePunctuation.universalSeparators + "]"

        // Never a space before a mark.
        result = replacing("\\s+(" + marks + ")", with: "$1", in: result)
        // A run of one separator is one separator.
        result = replacing("(" + separators + ")\\1+", with: "$1", in: result)
        // A separator touching a terminator: the terminator wins, whichever
        // order the model put them in.
        result = replacing(separators + "\\s*(" + terminators + ")", with: "$1", in: result)
        result = replacing("(" + terminators + ")\\s*" + separators, with: "$1", in: result)
        // Shouting and stammering. Four or more stops is an ellipsis that got
        // away; three stays an ellipsis.
        result = replacing("!{2,}", with: "!", in: result)
        result = replacing("\\?{2,}", with: "?", in: result)
        result = replacing("\\.{4,}", with: "...", in: result)
        result = replacing("([!?])\\.+", with: "$1", in: result)
        result = replacing("\\.([!?])", with: "$1", in: result)

        if punctuation.join == " " {
            // Always a space after a mark, unless another mark follows it —
            // that is an ellipsis or a quoted close, not two sentences.
            result = replacing(
                "(" + separators + ")(?=[^\\s"
                    + SentencePunctuation.universalMarks + "\\)\\]\"”’])",
                with: "$1 ",
                in: result
            )
            result = replacing(
                "(" + terminators + ")(?=[\\p{L}\\p{N}\u{E000}])",
                with: "$1 ",
                in: result
            )
        }

        // A mark with nothing in front of it, and a separator with nothing
        // after it, are both left over from something that was removed.
        result = replacing("^[\\s" + SentencePunctuation.universalMarks + "]+", with: "", in: result)
        result = replacing("(" + separators + ")+\\s*$", with: "", in: result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(
        _ pattern: String, with template: String, in text: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }

    // MARK: - Marks that are missing

    /// Phrases that start a new thought when they turn up mid-flow. Each is a
    /// discourse marker with no other job, which is what makes a sentence break
    /// in front of it safe.
    private static let sentenceStarters: [[String]] = [
        ["okay"], ["ok"], ["alright"], ["all", "right"],
        ["anyway"], ["anyhow"], ["by", "the", "way"], ["in", "any", "case"],
    ]

    /// Markers that take a comma when they open a sentence. `so` and `well` are
    /// missing on purpose: both open a sentence far more often without one.
    private static let openersTakingComma: [[String]] = [
        ["okay"], ["ok"], ["alright"], ["all", "right"],
        ["anyway"], ["anyhow"], ["however"], ["actually"],
        ["by", "the", "way"], ["in", "fact"], ["of", "course"], ["for", "example"],
    ]

    /// Conjunctions that take a comma when they join two full clauses.
    private static let clauseConjunctions: Set<String> = ["but", "so", "yet", "however"]

    /// After a conjunction these continue the phrase rather than opening a
    /// clause: "so that", "so much", "but as".
    private static let phraseFollowers: Set<String> = [
        "that", "much", "many", "far", "long", "as",
    ]

    private static let determiners: Set<String> = ["the", "a", "an"]

    /// Openers that are neither a subject nor an auxiliary but still start a
    /// sentence often enough to count as one beginning.
    private static let clauseOpeners: Set<String> = ["so", "well", "just", "first", "next"]

    /// Words that can open a clause of their own. The test for "is a full
    /// clause coming" is "does a subject start right here", which these are the
    /// common ones for.
    private static let clauseStarters: Set<String> = [
        "i", "im", "ive", "ill", "id", "you", "youre", "youve", "youll", "youd",
        "we", "weve", "well", "wed", "were", "they", "theyre", "theyve", "theyll",
        "he", "hes", "hed", "she", "shes", "shed", "it", "its", "thats", "this",
        "there", "theres", "my", "your", "our", "their", "his", "her",
        "the", "a", "an", "nobody", "everyone", "someone", "people", "lets",
        "maybe", "now", "then", "today", "tomorrow", "yesterday",
    ]

    /// After one of these, `okay` and `alright` are describing something —
    /// "the results came back okay" — rather than somebody starting a new
    /// sentence. Copulas and the particles that finish a phrasal verb, which is
    /// the other position an adjective lands in.
    private static let adjectivePredecessors: Set<String> = [
        "is", "are", "was", "were", "am", "be", "been", "being",
        "seem", "seems", "seemed", "look", "looks", "looked",
        "feel", "feels", "felt", "sound", "sounds", "sounded",
        "went", "goes", "going", "gone", "doing", "does", "works", "worked",
        "turned", "came", "back", "out", "up", "fine", "along",
        "not", "quite", "pretty", "totally", "perfectly", "really",
        "its", "thats", "everything", "anything", "something", "nothing",
        "all", "more", "less", "about", "mostly", "otherwise", "apparently",
    ]

    private static let auxiliaries: Set<String> = [
        "do", "does", "did", "dont", "doesnt", "didnt",
        "is", "are", "was", "were", "isnt", "arent", "wasnt", "werent",
        "can", "cant", "could", "couldnt", "will", "wont", "would", "wouldnt",
        "should", "shouldnt", "shall", "may", "might", "must",
        "have", "has", "had", "havent", "hasnt", "hadnt", "am",
    ]

    private static let questionWords: Set<String> = [
        "what", "whats", "when", "whens", "where", "wheres",
        "why", "whys", "who", "whos", "whom", "whose", "how", "hows",
    ]

    /// A `how` question may put a quantifier and its noun in front of the
    /// auxiliary: "How many people are coming?". That is a question shape, not
    /// the noun-clause shape that makes "what the problem is remains unclear"
    /// a statement.
    private static let howQuantifiers: Set<String> = ["many", "much"]

    private static let subjectPronouns: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "there",
        "that", "this", "anyone", "anybody", "someone", "somebody", "everyone",
    ]

    /// Longest sentence still short enough for the question test to be worth
    /// trusting. Past this a wh-word is far more often opening a noun clause.
    private static let maximumQuestionWords = 12

    private static func infer(_ text: String, punctuation: SentencePunctuation) -> String {
        var words = split(text)
        guard !words.isEmpty else { return text }
        splitAtStarters(&words, punctuation: punctuation)
        commaAfterOpeners(&words, punctuation: punctuation)
        commaBeforeConjunctions(&words, punctuation: punctuation)
        markQuestions(&words, punctuation: punctuation)
        return joined(words)
    }

    /// Ends the sentence in front of a discourse marker that has clearly started
    /// a new one. Requires a substantial unpunctuated clause behind it and a
    /// clause of its own in front, so a marker inside a sentence is left alone.
    private static func splitAtStarters(
        _ words: inout [Word],
        punctuation: SentencePunctuation
    ) {
        var index = 1
        while index < words.count {
            guard let length = match(sentenceStarters, in: words, at: index),
                  index + length + 2 <= words.count,
                  wordsSinceMark(words, before: index) >= 4,
                  words[index - 1].trailing.isEmpty,
                  !adjectivePredecessors.contains(words[index - 1].key),
                  // A marker only ends the previous sentence when a clause of
                  // its own follows. "The results came back okay and we
                  // shipped" is one sentence; "…came back okay lets ship" is
                  // two, and the difference is entirely the next word.
                  startsClause(words[index + length].key)
            else {
                index += 1
                continue
            }
            words[index - 1].trailing = punctuation.terminator
            matchCaseOfSentence(&words, newSentenceAt: index)
            index += length
        }
    }

    /// Quantifiers that turn an opener into a phrase. "However many people come"
    /// means "no matter how many", and the comma would say the opposite.
    private static let quantifierFollowers: Set<String> = [
        "many", "much", "long", "far", "little", "few", "often", "else",
    ]

    /// "Okay we should ship" — the marker opens the sentence and the rest of it
    /// follows, which in writing takes a comma.
    private static func commaAfterOpeners(
        _ words: inout [Word],
        punctuation: SentencePunctuation
    ) {
        for index in words.indices {
            guard opensSentence(words, at: index, punctuation: punctuation),
                  let length = match(openersTakingComma, in: words, at: index),
                  words[index + length - 1].trailing.isEmpty,
                  index + length + 2 <= words.count,
                  !quantifierFollowers.contains(words[index + length].key)
            else { continue }
            words[index + length - 1].trailing = punctuation.separator
        }
    }

    /// "…ship it on Friday but I don't know…" — a conjunction joining two full
    /// clauses takes a comma in front of it.
    private static func commaBeforeConjunctions(
        _ words: inout [Word],
        punctuation: SentencePunctuation
    ) {
        for index in words.indices where index >= 4 && index + 2 < words.count {
            let next = words[index + 1].key
            guard clauseConjunctions.contains(words[index].key),
                  words[index].leading.isEmpty,
                  words[index].trailing.isEmpty,
                  words[index - 1].trailing.isEmpty,
                  wordsSinceMark(words, before: index) >= 4,
                  clauseStarters.contains(next),
                  // "so that", "so much", "but as" — a phrase, not a new clause.
                  !phraseFollowers.contains(next),
                  // A determiner is the ambiguous case: "…but the tests are
                  // failing" is a clause, "…but the truth" is an object. Only
                  // the first has room for a verb after it.
                  !determiners.contains(next) || index + 4 <= words.count
            else { continue }
            words[index - 1].trailing = punctuation.separator
        }
    }

    /// Puts a question mark on a sentence that asks something. Applies to a
    /// sentence with no terminator at all and to one the model closed with a
    /// plain full stop; `!` is left alone, because someone chose it.
    private static func markQuestions(
        _ words: inout [Word],
        punctuation: SentencePunctuation
    ) {
        for sentence in sentences(words, punctuation: punctuation) {
            let existing = words[sentence.upperBound].trailing
                .last { punctuation.terminators.contains($0) }
            // A sentence the model closed with `!` was a choice. One it closed
            // with the plain terminator, or did not close at all, was not.
            guard existing == nil || String(existing!) == punctuation.terminator,
                  sentence.count <= maximumQuestionWords,
                  isQuestion(words, sentence)
            else { continue }
            close(&words[sentence.upperBound], with: punctuation.question, punctuation: punctuation)
        }
    }

    /// Closes a word with `mark`, replacing the terminator it already carries
    /// rather than doubling it, and going *inside* any quote or bracket. A
    /// question that reached the model in quotes ends `it?"`, never `it."?`.
    private static func close(
        _ word: inout Word,
        with mark: String,
        punctuation: SentencePunctuation
    ) {
        if let existing = word.trailing.lastIndex(where: { punctuation.terminators.contains($0) }) {
            word.trailing.remove(at: existing)
        }
        let wrapper = word.trailing.firstIndex { isQuote($0) || ")]}»".contains($0) }
        word.trailing.insert(contentsOf: mark, at: wrapper ?? word.trailing.endIndex)
    }

    /// Modals that turn an inverted `had`/`were` opening into a condition
    /// rather than a question: "Had I known that, I would have called."
    private static let conditionalModals: Set<String> = [
        "would", "could", "should", "might", "wouldve", "couldve", "shouldve",
    ]

    private static func isQuestion(_ words: [Word], _ sentence: ClosedRange<Int>) -> Bool {
        let keys = sentence.map { words[$0].key }
        guard keys.count >= 2 else { return false }
        if questionWords.contains(keys[0]) {
            // "What time is it" asks; "What I meant was simple" and "what the
            // problem is remains unclear" state. A question inverts the
            // auxiliary to the front, so it turns up within a word or two of
            // the wh-word; an embedded noun clause puts a whole subject there
            // first and pushes the auxiliary back.
            //
            // Two words of room is the normal allowance. "How many people are
            // coming" has a quantifier and its noun in front of the auxiliary,
            // so it gets one extra explicitly-recognized shape. Reading "what
            // john said was wrong" as a question is not worth that wider rule.
            for offset in 1..<min(keys.count, 3) {
                if subjectPronouns.contains(keys[offset]) { return false }
                if determiners.contains(keys[offset]) { return false }
                if auxiliaries.contains(keys[offset]) { return true }
            }
            if keys.count >= 4,
               keys[0] == "how",
               howQuantifiers.contains(keys[1]),
               auxiliaries.contains(keys[3]) {
                return true
            }
            return false
        }
        guard auxiliaries.contains(keys[0]), subjectPronouns.contains(keys[1]) else { return false }
        // "Had I known" and "Were it up to me" invert the same way a question
        // does; the modal further along is what tells them apart.
        if keys[0] == "had" || keys[0] == "were" {
            return !keys.dropFirst(2).contains { conditionalModals.contains($0) }
        }
        return true
    }

    // MARK: - Inference helpers

    /// Whether the phrase at `index` is one of `phrases`, and how long it is.
    private static func match(_ phrases: [[String]], in words: [Word], at index: Int) -> Int? {
        for phrase in phrases where index + phrase.count <= words.count {
            var matched = true
            for (offset, key) in phrase.enumerated() where words[index + offset].key != key {
                matched = false
                break
            }
            // A mark inside the phrase means it is not being said as one.
            if matched {
                for offset in 0..<(phrase.count - 1)
                where !words[index + offset].trailing.isEmpty {
                    matched = false
                    break
                }
            }
            if matched { return phrase.count }
        }
        return nil
    }

    /// Whether a clause could start at this word. The question a split has to
    /// answer is "is a new sentence beginning here", and a subject, an
    /// auxiliary, or a question word is what one begins with.
    private static func startsClause(_ key: String) -> Bool {
        clauseStarters.contains(key)
            || auxiliaries.contains(key)
            || questionWords.contains(key)
            || clauseOpeners.contains(key)
    }

    private static func opensSentence(
        _ words: [Word],
        at index: Int,
        punctuation: SentencePunctuation
    ) -> Bool {
        index == 0 || ends(words[index - 1], punctuation: punctuation)
    }

    /// How many words back to the last punctuation of any kind. This is the
    /// stand-in for "is there a whole clause behind me": a rule that would add a
    /// mark four words after the last one is guessing, not repairing.
    private static func wordsSinceMark(_ words: [Word], before index: Int) -> Int {
        var count = 0
        var cursor = index - 1
        while cursor >= 0 {
            count += 1
            if !words[cursor].trailing.isEmpty { break }
            cursor -= 1
        }
        return count
    }

    private static func sentences(
        _ words: [Word],
        punctuation: SentencePunctuation
    ) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        var start = 0
        for index in words.indices where ends(words[index], punctuation: punctuation) {
            result.append(start...index)
            start = index + 1
        }
        if start < words.count { result.append(start...(words.count - 1)) }
        return result
    }

    /// Capitalizes a sentence this stage just created, but only when the
    /// sentence it was split out of was capitalized too.
    ///
    /// The alternative — always capitalizing — puts a stray capital in the
    /// middle of `clean` style output, which exists to flatten exactly that.
    /// Following the text's own convention is right on both routes: a gateway
    /// transcript arrives already cased and gets a capital, a raw local one
    /// arrives lowercase and is left for ``TranscriptStyler`` to decide about.
    private static func matchCaseOfSentence(_ words: inout [Word], newSentenceAt index: Int) {
        var cursor = index - 1
        var sentenceStart = index
        while cursor >= 0 {
            if !words[cursor].trailing.isEmpty && cursor != index - 1 { break }
            sentenceStart = cursor
            cursor -= 1
        }
        guard words[sentenceStart].startsUppercase,
              let first = words[index].text.first(where: \.isLetter),
              first.isLowercase
        else { return }
        var text = words[index].text
        guard let position = text.firstIndex(of: first) else { return }
        text.replaceSubrange(position...position, with: String(first).uppercased())
        words[index].text = text
    }
}
