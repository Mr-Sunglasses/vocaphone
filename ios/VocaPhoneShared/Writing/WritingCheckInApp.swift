import Foundation

/// The Writing check screen's two decisions, kept out of the view so they can
/// be tested: whether to check a text at all, and when to stop checking it.
/// Mirrors `writingCheckApplies` and `checkUntilCancelled` in
/// android/.../ui/WritingCheckScreen.kt.
extension WritingCheck {
    /// How many words text needs before the language test decides whether
    /// to check it. See `applies(to:isDictionaryWord:)`.
    static let languageTestMinimumWords = 6

    /// Whether the Writing check screen checks `text` at all. The rules are
    /// English ones: on a French sentence, "dont" would be "corrected" to
    /// "don't". So text is left alone only when it is clearly not English,
    /// by the test the keyboard makes, with the keyboard's word list as
    /// `isDictionaryWord`.
    ///
    /// That test is only trusted from `languageTestMinimumWords` words on. It
    /// calls text English on two marker words, or on two thirds of its words
    /// being in the list, and a misspelling or a name is a word the list does
    /// not know. Below six words a single unknown word is enough to fail it:
    /// "please recieve" is half unknown, and a lone "recieve" has no known
    /// word at all. From six on, English text can carry two (a typo and a
    /// name) and still pass, and a whole French sentence still fails. Shorter
    /// text is always checked: the cost of being wrong there is one
    /// suggestion to ignore, and the cost of skipping is a missed fix on
    /// exactly the text, a selected word or a short message, people most
    /// often bring here.
    ///
    /// The keyboards ask the same, with `spelling` so that typed text's own
    /// typos do not vote it foreign (`typedEnglish(_:isDictionaryWord:spelling:)`).
    static func applies(
        to text: String,
        isDictionaryWord: (String) -> Bool = EnglishWords.contains,
        spelling: WritingSpelling? = nil
    ) -> Bool {
        guard text.contains(where: \.isLetter) else { return false }
        let words = text.split(whereSeparator: \.isWhitespace).count { $0.contains(where: \.isLetter) }
        return words < languageTestMinimumWords
            || isEnglish(text) { typedEnglish($0, isDictionaryWord: isDictionaryWord, spelling: spelling) }
    }

    /// `TranscriptRepair.isEnglish` for text someone typed, where the words
    /// that would tell it apart are the very ones misspelled. The transcript
    /// test wants two marker words or two thirds of the words in
    /// `isDictionaryWord`, and counts "teh" and "aiport" as foreign, so
    /// "Teh aiport wil be busy tomorow" failed it and was never checked: the
    /// more mistakes, the surer the test was that the text was not English.
    ///
    /// Two things change here. A slip of a marker word (one swapped pair of
    /// letters, or one letter doubled or undoubled: "teh", "adn", "becuase",
    /// "thier") counts as that marker, since another language does not
    /// produce the English word's own misspelling. And once the text has a
    /// marker, a word `spelling` knows or can correct counts as English too.
    /// A French or Hindi sentence written in Latin letters has no marker, so
    /// it still fails, however many of its words sit near an English one.
    /// As `WritingLanguage.typedEnglish` on Android.
    static func typedEnglish(
        _ text: String,
        isDictionaryWord: (String) -> Bool,
        spelling: WritingSpelling?
    ) -> Bool {
        let keys = TranscriptRepair.wordKeys(in: text)
        let markers = Set(keys.compactMap { TranscriptRepair.isEnglishMarker($0) ? $0 : markerSlip($0) })
        // More distinct words of another language's commonest than English markers:
        // "kal milte hai, tu aa jana time pe" has "time", and "je ne sais pas"
        // is all words the English list happens to hold.
        let foreign = Set(keys.filter { foreignFunctionWords.contains($0) }).count
        if foreign >= 2, foreign > markers.count { return false }
        if TranscriptRepair.isEnglish(text, isDictionaryWord: isDictionaryWord) { return true }
        if TranscriptRepair.hasForeignLetter(text) { return false }
        guard keys.count >= 2 else { return false }
        if markers.count >= 2 { return true }
        guard !markers.isEmpty, let spelling else { return false }
        let english = keys.count { key in
            isDictionaryWord(key) || markerSlip(key) != nil || spelling.isKnown(key) || spelling.suggest(key) != nil
        }
        return english * 3 >= keys.count * 2
    }

    /// The commonest function words of the other languages people type in
    /// Latin letters here (French, Spanish, German, Italian, Portuguese and
    /// Hindi as typed in chat), less any that are English words too. As
    /// `FOREIGN_FUNCTION_WORDS` in android/.../writing/WritingLanguage.kt.
    static let foreignFunctionWords: Set<String> = [
        "je", "ne", "le", "cest", "pas", "que", "qui", "est", "et", "les", "des", "une", "il", "elle",
        "nous", "vous", "sont", "avec", "dans", "mais", "ce", "cette", "sur", "oui", "merci", "suis", "sais", "fait",
        "bien", "toi", "aux", "du", "es", "uno", "una", "por", "pero", "muy", "mi", "tu", "su", "esta",
        "este", "se", "hola", "gracias", "bueno", "nada", "todo", "tengo", "quiero", "hacer", "ahora", "der", "das", "und",
        "ist", "nicht", "ich", "wir", "sie", "auf", "ein", "eine", "auch", "noch", "sehr", "aber", "wie", "wo",
        "ja", "nein", "danke", "sono", "molto", "grazie", "muito", "obrigado", "hai", "hain", "kya", "nahi", "nahin", "aur",
        "mein", "tum", "kar", "raha", "rahe", "rahi", "aap", "bhi", "ka", "ki", "ke", "yeh", "woh", "kal",
        "abhi", "acha", "accha", "bhai", "yaar", "kaise", "kaisa", "kab", "kahan", "kyun", "kyu", "haan", "theek", "thik",
        "mujhe", "tujhe", "hoga", "hogi", "karna", "karenge", "jaana", "chal", "chalo", "liye", "wala", "wali", "bahut", "bohot",
        "voici", "parle", "souvent", "aussi", "toujours", "rien", "beaucoup", "comme", "peut", "veux", "vais", "avoir", "faire", "quoi",
        "alors", "pourquoi", "como", "donde", "quien", "porque", "tambien", "siempre", "estoy", "eres", "bitte", "heute", "keine", "habe",
        "zeit", "kaha", "kuch", "sab", "kyunki", "lekin", "toh", "aaj",
    ]

    /// The marker `key` is one slip of, if any: a swapped pair, or one letter doubled or undoubled.
    static func markerSlip(_ key: String) -> String? {
        let chars = Array(key)
        guard chars.count >= 3, !TranscriptRepair.isEnglishMarker(key) else { return nil }
        for i in 0..<(chars.count - 1) {
            if chars[i] == chars[i + 1] {
                // Undoubled: "tthe" → "the".
                var undoubled = chars
                undoubled.remove(at: i)
                if TranscriptRepair.isEnglishMarker(String(undoubled)) { return String(undoubled) }
                continue
            }
            var swapped = chars
            swapped.swapAt(i, i + 1)
            if TranscriptRepair.isEnglishMarker(String(swapped)) { return String(swapped) }
        }
        for i in chars.indices {
            // A dropped double letter: "realy" → "really", "anythng" is not one.
            var doubled = chars
            doubled.insert(chars[i], at: i)
            if TranscriptRepair.isEnglishMarker(String(doubled)) { return String(doubled) }
        }
        return nil
    }

    /// At most one word in this many may be spelled outside a–z for text to
    /// still be English. See `isEnglish(_:isEnglish:)`.
    static let borrowedWordShare = 4

    /// `isEnglish` (the transcript test, which calls any text with an
    /// accented letter foreign) asked of `text` without its borrowed words.
    /// English borrows "café", "naïve" and "résumé", and one of them in a
    /// sentence should not switch off every check in it. So when no more than
    /// one word in `borrowedWordShare` has a letter outside a–z, those words
    /// are left out and the rest decides; more than that and the text is not
    /// English.
    ///
    /// An accent is still evidence of another language, and dropping it
    /// leaves the dictionary half of `isEnglish` easy to fool: "le", "tu",
    /// "as" and "menu" are all English words, so "C'est le café dont tu as le
    /// menu." would pass on its other words. The rest must also carry an
    /// English marker word (`TranscriptRepair.englishMarkers(in:)`) other
    /// than "dont", which is French as well and is the very word the rules
    /// would "correct", or at least no word of `foreignFunctionWords` ("le",
    /// "tu"). As `WritingLanguage.isEnglish` on Android.
    static func isEnglish(_ text: String, isEnglish: (String) -> Bool) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
        let borrowed = words.filter(isBorrowed)
        if borrowed.isEmpty { return isEnglish(text) }
        if borrowed.count * borrowedWordShare > words.count { return false }
        let rest = words.filter { !isBorrowed($0) }.joined(separator: " ")
        // A marker, or at least none of another language's commonest words:
        // "My flight to São Paulo leaves at 11:50 pm." has no marker at all.
        return isEnglish(rest) && (
            !TranscriptRepair.englishMarkers(in: rest).subtracting(sharedMarkers).isEmpty
                || !TranscriptRepair.wordKeys(in: rest).contains(where: foreignFunctionWords.contains)
        )
    }

    /// English marker words that are words in French too.
    private static let sharedMarkers: Set<String> = ["dont"]

    private static func isBorrowed(_ word: Substring) -> Bool {
        word.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic && !("a"..."z").contains(scalar) && !("A"..."Z").contains(scalar)
        }
    }

    /// `check`, with a second pass after `retryAfter` if the model was still
    /// loading, that gives up when its task is cancelled: the model is asked
    /// nothing more, the retry never starts, and the answer is nil.
    func checkUntilCancelled(
        _ text: String,
        model: Model?,
        options: Options,
        retryAfter: Duration = .milliseconds(1200)
    ) async -> Report? {
        let asked: Model? = model.map { model in
            { sentence in Task.isCancelled ? nil : model(sentence) }
        }
        var report = check(text, model: asked, options: options)
        if report.modelPending {
            // The model was loading; asking started it. Once more, a moment later.
            try? await Task.sleep(for: retryAfter)
            guard !Task.isCancelled else { return nil }
            report = check(text, model: asked, options: options)
        }
        return Task.isCancelled ? nil : report
    }
}
