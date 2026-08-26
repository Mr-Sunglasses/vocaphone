import Foundation

/// The last pass on a Roman Hinglish transcript, and the only thing standing
/// between a good decode and Devanagari in a text field.
///
/// A mirror of
/// `android/app/src/main/java/com/vocahq/vocaphone/core/HinglishNormalizer.kt`,
/// tables included. The two clients must produce the same transcript from the
/// same words, and the tables are where a divergence would hide.
///
/// The Hinglish model writes Latin nearly all of the time. Nearly is the
/// problem: on an unfamiliar proper noun, or a stretch of clean Hindi with no
/// English in it, it can fall back to the script it was fine-tuned away from.
/// Deleting that would silently lose words the user said, so it is
/// transliterated instead — `DevanagariRomanizer` turns "में" into text rather
/// than into nothing.
///
/// Everything else here is deliberately small. This is not a corrector: it does
/// not repair grammar, does not second-guess word choice, and never rewrites a
/// word spelled like English. Over-correction on a dictation transcript is worse
/// than an inconsistent spelling, because the user cannot tell it happened.
///
/// Runs entirely on the device. No model, no network, no lookup service — the
/// whole layer is the tables below, and the convention they encode is written
/// down in `docs/hinglish-roman.md`.
enum HinglishNormalizer {

    /// Which passes to run.
    ///
    /// Configurable because the two spelling passes are conventions rather than
    /// facts. Someone who writes "kyon" is not wrong, and a build that wanted to
    /// leave their spelling alone should be able to say so without also giving
    /// up transliteration, which is not a preference at all.
    struct Options: Sendable {
        /// Rewrite Devanagari as Latin rather than leaving or dropping it.
        var transliterateDevanagari: Bool
        /// Settle transliterator output on one spelling per word.
        var applyRomanizedConventions: Bool
        /// Settle the handful of Hindi spellings that are never English words.
        var applyGlobalConventions: Bool
        /// Collapse whitespace and turn a danda into a full stop.
        var normalizePunctuation: Bool

        init(
            transliterateDevanagari: Bool = true,
            applyRomanizedConventions: Bool = true,
            applyGlobalConventions: Bool = true,
            normalizePunctuation: Bool = true
        ) {
            self.transliterateDevanagari = transliterateDevanagari
            self.applyRomanizedConventions = applyRomanizedConventions
            self.applyGlobalConventions = applyGlobalConventions
            self.normalizePunctuation = normalizePunctuation
        }

        static let `default` = Options()
    }

    static func containsDevanagari(_ text: String) -> Bool {
        DevanagariRomanizer.containsDevanagari(text)
    }

    static func normalize(_ text: String, options: Options = .default) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let masked = mask(text)
        var result = masked.text
        if options.transliterateDevanagari {
            result = transliterateWithConventions(
                result,
                applyConventions: options.applyRomanizedConventions
            )
        }
        if options.applyGlobalConventions {
            result = applyGlobalConventions(result)
        }
        if options.normalizePunctuation {
            result = normalizePunctuation(result)
        }
        return restore(result, tokens: masked.tokens)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Masking

    private struct Masked {
        let text: String
        let tokens: [String]
    }

    /// Spans that must survive every pass below untouched.
    ///
    /// A URL, an email address, a file path, a shell command, an @handle: none of
    /// them are language, and all of them break if a spelling rule reaches
    /// inside. Devanagari inside such a span stays Devanagari on purpose — a
    /// transliterated host name is a broken link rather than a readable one.
    ///
    /// Case sensitivity is load-bearing, which is why there is no
    /// `caseInsensitive` option on the whole pattern: the last alternative is
    /// what makes `API` and `HTTP` survive, and case-folding it would match every
    /// ordinary two-to-eight-letter word and mask the entire sentence.
    private static let protectedSpans = try! NSRegularExpression(
        pattern: [
            // A URL or a bare host.
            #"(?i:\b(?:[a-z][a-z0-9+.-]*://|www\.)\S+)"#,
            // An email address.
            #"(?i:\b[\w.+-]+@[\w-]+\.[\w.-]+\b)"#,
            // A path or a command: anything with an internal slash.
            #"\S*[/\\]\S*"#,
            // A filename or a dotted identifier.
            #"(?i:\b\w+\.[a-z0-9]{1,8}\b)"#,
            // A handle or a hashtag.
            #"[@#][\w.-]+"#,
            // An abbreviation the model wrote in capitals: API, GPU, HTTP.
            #"\b[A-Z][A-Z0-9]{1,7}\b"#,
        ].joined(separator: "|")
    )

    private static let placeholderOpen = "\u{0001}"
    private static let placeholderClose = "\u{0002}"
    private static let placeholder = try! NSRegularExpression(
        pattern: "\u{0001}(\\d+)\u{0002}"
    )

    private static func mask(_ text: String) -> Masked {
        var tokens: [String] = []
        var result = ""
        var cursor = text.startIndex
        let matches = protectedSpans.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches {
            guard let range = Range(match.range, in: text), range.lowerBound >= cursor else {
                continue
            }
            result += text[cursor..<range.lowerBound]
            result += "\(placeholderOpen)\(tokens.count)\(placeholderClose)"
            tokens.append(String(text[range]))
            cursor = range.upperBound
        }
        result += text[cursor...]
        return Masked(text: result, tokens: tokens)
    }

    private static func restore(_ text: String, tokens: [String]) -> String {
        replacing(text, placeholder) { match in
            guard let index = Int(match.dropFirst().dropLast()), index < tokens.count else {
                return match
            }
            return tokens[index]
        }
    }

    // MARK: - Transliteration

    /// Transliterates each Devanagari run and settles its spelling immediately.
    ///
    /// Doing it here rather than over the finished string is what makes
    /// `romanizedConventions` safe. "men" out of the transliterator is में; "men"
    /// that arrived already in Latin is the English word, and rewriting that to
    /// "mein" is exactly the over-correction this layer must not do. Provenance
    /// is only knowable at this moment, so the rule is applied at this moment.
    private static func transliterateWithConventions(
        _ text: String,
        applyConventions: Bool
    ) -> String {
        guard DevanagariRomanizer.containsDevanagari(text) else { return text }
        let romanized = DevanagariRomanizer.romanize(text)
        guard applyConventions else { return romanized }
        // A word already in the source cannot have come out of the
        // transliterator, so it is left alone whatever the table says.
        let original = Set(words(in: text))
        return replacing(romanized, wordPattern) { word in
            if original.contains(word) { return word }
            guard let replacement = romanizedConventions[word.lowercased()] else { return word }
            return matchCase(word, replacement)
        }
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"\p{L}+"#)

    private static func words(in text: String) -> [String] {
        wordPattern
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// One spelling per word for transliterator output, where the mechanical
    /// answer is not the one people type.
    ///
    /// Short by design. The romanizer's own rules already produce "mujhe",
    /// "nahin", "hai" and "theek"; these are the leftovers. में is the clearest:
    /// it is म + े + ं, mechanically "men", and every Hinglish speaker writes
    /// "mein".
    private static let romanizedConventions: [String: String] = [
        "men": "mein",
        "kyon": "kyun",
        "kyonki": "kyunki",
        "hon": "hoon",
        "hun": "hoon",
        "jaen": "jayen",
    ]

    // MARK: - Global conventions

    /// Spellings settled across the whole transcript, including text the model
    /// already wrote in Latin.
    ///
    /// Every key has to be a form that is *not* an English word, because by this
    /// point provenance is gone and a collision would rewrite English. That rules
    /// out the tempting ones — "to", "the", "is", "men" — and leaves a short list
    /// where the rewrite is unambiguous.
    private static let globalConventions: [String: String] = [
        "muje": "mujhe",
        "mujey": "mujhe",
        "mujhy": "mujhe",
        "kyu": "kyun",
        "kyoon": "kyun",
        "kyuki": "kyunki",
        "kyunke": "kyunki",
        "nahi": "nahin",
        "nhi": "nahin",
        "thik": "theek",
        "thk": "theek",
        "acha": "accha",
        "achha": "accha",
        "bahot": "bahut",
        "bhot": "bahut",
        "kese": "kaise",
        "krna": "karna",
        "krke": "karke",
        "smjh": "samajh",
    ]

    private static func applyGlobalConventions(_ text: String) -> String {
        let settled = replacing(text, wordPattern) { word in
            guard let replacement = globalConventions[word.lowercased()] else { return word }
            return matchCase(word, replacement)
        }
        return replacing(settled, heyPattern) { _ in "hai" }
    }

    /// "theek hey" is "theek hai"; "Hey, ..." is English and stays.
    ///
    /// The one rule that needs a guard rather than a table, because "hey" is a
    /// real English word. It is only rewritten mid-sentence and lowercase:
    /// English "hey" is an opener, and an opener is capitalized or followed by a
    /// comma. Wrong in the safe direction leaves a spelling slightly off; wrong
    /// in the other direction rewrites what someone said.
    private static let heyPattern = try! NSRegularExpression(
        pattern: #"(?<=\S )hey\b(?![,!])"#
    )

    /// Keeps a rewritten word in the case it arrived in.
    private static func matchCase(_ original: String, _ replacement: String) -> String {
        if original.count > 1, original.allSatisfy(\.isUppercase) {
            return replacement.uppercased()
        }
        if original.first?.isUppercase == true {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    // MARK: - Punctuation

    private static let repeatedSpaces = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let spaceBeforeMark = try! NSRegularExpression(pattern: #" +([,.!?;:])"#)
    private static let markNeedingSpace = try! NSRegularExpression(
        pattern: #"([,.!?;:])(?=[^\s\d,.!?;:])"#
    )

    /// Whitespace and the two marks the script change leaves behind.
    ///
    /// The danda is a Devanagari full stop with no business in a Latin sentence;
    /// `DevanagariRomanizer` already converts the ones attached to a word, and
    /// this catches a free-standing one. Capitalization and sentence terminators
    /// are deliberately absent — `TranscriptStyler` runs after this and owns them
    /// for every language.
    private static func normalizePunctuation(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "।", with: ".")
        result = result.replacingOccurrences(of: "॥", with: ".")
        result = replacing(result, repeatedSpaces) { _ in " " }
        result = replacing(result, spaceBeforeMark) { String($0.drop { $0 == " " }) }
        result = replacing(result, markNeedingSpace) { "\($0) " }
        return result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    // MARK: - Regex helper

    /// `NSRegularExpression` with a closure over the matched text, which is what
    /// Kotlin's `Regex.replace { }` gives for free and Foundation does not.
    private static func replacing(
        _ text: String,
        _ pattern: NSRegularExpression,
        _ transform: (String) -> String
    ) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), range.lowerBound >= cursor else {
                continue
            }
            result += text[cursor..<range.lowerBound]
            result += transform(String(text[range]))
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
