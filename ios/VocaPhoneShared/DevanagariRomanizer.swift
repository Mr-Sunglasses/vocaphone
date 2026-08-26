import Foundation

/// Devanagari to Latin, in the spelling people actually type.
///
/// A line-for-line mirror of
/// `android/app/src/main/java/com/vocahq/vocaphone/core/DevanagariRomanizer.kt`.
/// The two must agree character for character: the same dictation on the two
/// phones has to produce the same transcript, and this is the layer where a
/// divergence would be invisible until someone compared two screenshots.
///
/// This is not IAST and deliberately not reversible. IAST would give "ājˈ mujhe"
/// where a Hinglish speaker writes "Aaj mujhe", and a transcript that reads like
/// a linguistics paper is not the feature. The scheme is documented in
/// `docs/hinglish-roman.md`; the three rules that make it look natural are the
/// ones below, and each is here because the naive answer is visibly wrong.
///
/// **Schwa deletion.** Every Devanagari consonant carries an implicit `a` that
/// Hindi does not always pronounce. Rendering it always gives "gharaa" for घर and
/// "karanaa" for करना. The implicit vowel is dropped at the end of a word, and
/// mid-word when the next syllable carries a written vowel of its own — करना
/// becomes "karna" while समझ stays "samajh", because in समझ the following
/// syllable has no written vowel either. The mid-word case never fires on the
/// first syllable: without that guard पता collapses to "pta".
///
/// **Long vowels shorten at the end.** आ is "aa" in आज ("aaj") and "a" in करना
/// ("karna"); ई is "ee" in ठीक ("theek") and "i" in कभी ("kabhi"). Finality is
/// judged after schwa deletion and ignores a trailing nasal, so नहीं is "nahin"
/// rather than "naheen".
///
/// **Anusvara is `n`, except before a lip consonant.** संभव is "sambhav" and
/// अंदर is "andar"; one letter, two sounds, and the following consonant decides.
///
/// Nothing outside the Devanagari block is touched. Latin runs pass through
/// unchanged, which is what keeps the English half of a code-switched sentence
/// spelled the way it was spoken.
enum DevanagariRomanizer {

    // Scalars, not Characters, and that distinction is the whole correctness of
    // this file. Swift's `Character` is a grapheme cluster, so "मु" — a
    // consonant with a vowel sign attached — arrives as one indivisible
    // Character and a Character-by-Character parser can never see the matra it
    // has to read. Kotlin iterates UTF-16 units and sees the two separately,
    // which is the behaviour being mirrored. Every table key below is a single
    // scalar for the same reason.
    private static let virama: Unicode.Scalar = "\u{094D}"
    private static let nukta: Unicode.Scalar = "\u{093C}"
    private static let anusvara: Unicode.Scalar = "\u{0902}"
    private static let chandrabindu: Unicode.Scalar = "\u{0901}"
    private static let visarga: Unicode.Scalar = "\u{0903}"
    private static let zwj: Unicode.Scalar = "\u{200D}"
    private static let zwnj: Unicode.Scalar = "\u{200C}"

    private static let nasalSigns: Set<Unicode.Scalar> = [anusvara, chandrabindu, visarga]
    private static let joiners: Set<Unicode.Scalar> = [zwj, zwnj]
    private static let labials: Set<Character> = ["p", "b", "m"]

    /// Whether `text` contains anything this romanizer would rewrite.
    static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isDevanagari)
    }

    private static func isDevanagari(_ scalar: Unicode.Scalar) -> Bool {
        (0x0900...0x097F).contains(Int(scalar.value))
    }

    /// A danda and a Devanagari digit share the block with the letters but are
    /// not part of the akshara model, and swallowing them into the word breaks
    /// the rule that decides where a word ends: with the danda counted, ठीक। has
    /// a syllable after क and the implicit vowel survives as "theeka.".
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        (isDevanagari(scalar) && standalone[scalar] == nil) || joiners.contains(scalar)
    }

    /// Romanizes every Devanagari run in `text`, leaving everything else exactly
    /// as it arrived.
    static func romanize(_ text: String) -> String {
        guard containsDevanagari(text) else { return text }
        var out = ""
        out.reserveCapacity(text.count + text.count / 2)
        var word: [Unicode.Scalar] = []

        func flush() {
            guard !word.isEmpty else { return }
            out += romanizeWord(word)
            word.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if isWordScalar(scalar) {
                word.append(scalar)
            } else if let mapped = standalone[scalar] {
                flush()
                out += mapped
            } else {
                flush()
                out.unicodeScalars.append(scalar)
            }
        }
        flush()
        return out
    }

    /// One written vowel, or the implicit one a bare consonant carries.
    private enum Vowel {
        case a, aa, i, ii, u, uu, ri, e, ai, o, au

        /// The final-position spelling; only the long vowels differ.
        func render(final: Bool) -> String {
            switch self {
            case .a: "a"
            case .aa: final ? "a" : "aa"
            case .i: "i"
            case .ii: final ? "i" : "ee"
            case .u: "u"
            case .uu: final ? "u" : "oo"
            case .ri: "ri"
            case .e: "e"
            case .ai: "ai"
            case .o: "o"
            case .au: "au"
            }
        }
    }

    /// One syllable: an onset, the vowel that follows it, and any nasal or
    /// visarga hanging off the end.
    ///
    /// `implicit` is the whole reason this is a struct rather than a string: an
    /// `a` that was written (अ, ा) and an `a` that is merely implied look the
    /// same once rendered, and only the implied one may be deleted.
    private struct Syllable {
        var onset: String
        var vowel: Vowel?
        var implicit: Bool
        var nasal: String = ""
    }

    private static func romanizeWord(_ word: [Unicode.Scalar]) -> String {
        var syllables = parse(word)
        applySchwaDeletion(&syllables)
        return render(syllables)
    }

    private static func parse(_ word: [Unicode.Scalar]) -> [Syllable] {
        var syllables: [Syllable] = []
        var index = 0
        while index < word.count {
            let scalar = word[index]
            if joiners.contains(scalar) {
                index += 1
            } else if let vowel = independentVowels[scalar] {
                syllables.append(Syllable(onset: "", vowel: vowel, implicit: false))
                index += 1
            } else if let base = consonants[scalar] {
                var onset = base
                index += 1
                if index < word.count, word[index] == nukta {
                    onset = nuktaForms[scalar] ?? onset
                    index += 1
                }
                var vowel: Vowel? = .a
                var implicit = true
                if index < word.count {
                    if word[index] == virama {
                        vowel = nil
                        implicit = false
                        index += 1
                    } else if let matra = matras[word[index]] {
                        vowel = matra
                        implicit = false
                        index += 1
                    }
                }
                syllables.append(Syllable(onset: onset, vowel: vowel, implicit: implicit))
            } else {
                // Accents and rare editorial signs. They have no Latin spelling
                // worth guessing at, so they are dropped rather than passed
                // through as a character nobody can read. Digits and the danda
                // never reach here: they end the word instead.
                index += 1
            }
            // A nasal or visarga binds to the syllable it follows, whatever
            // produced that syllable. With nothing to bind to — a word opening
            // with a stray sign — it is dropped.
            while index < word.count, nasalSigns.contains(word[index]) {
                if !syllables.isEmpty {
                    syllables[syllables.count - 1].nasal = word[index] == visarga ? "h" : "n"
                }
                index += 1
            }
        }
        return syllables
    }

    /// Drops the implicit `a` where Hindi does not pronounce it: word-finally
    /// always, and mid-word only when the next syllable carries a written vowel
    /// — never on the first syllable, which is what keeps पता from becoming
    /// "pta".
    private static func applySchwaDeletion(_ syllables: inout [Syllable]) {
        for index in syllables.indices {
            guard syllables[index].implicit, !syllables[index].onset.isEmpty else { continue }
            let isLast = index == syllables.count - 1
            let nextHasWrittenVowel = !isLast
                && syllables[index + 1].vowel != nil
                && !syllables[index + 1].implicit
            if isLast || (index > 0 && nextHasWrittenVowel) {
                syllables[index].vowel = nil
                syllables[index].implicit = false
            }
        }
    }

    private static func render(_ syllables: [Syllable]) -> String {
        // "Last vowel" is not the test, and getting that wrong turns आज into
        // "aj": schwa deletion leaves ज carrying no vowel at all, so the ā before
        // it looks final while a whole consonant still follows. What counts is
        // whether any letter comes after — onset or vowel. A trailing nasal is
        // transparent, which is why नहीं is "nahin" and not "naheen".
        let lastLetterIndex = syllables.lastIndex { !$0.onset.isEmpty || $0.vowel != nil }
        var out = ""
        for (index, syllable) in syllables.enumerated() {
            out += syllable.onset
            if let vowel = syllable.vowel {
                out += vowel.render(final: index == lastLetterIndex)
            }
            if syllable.nasal == "n" {
                // One letter, two sounds: संभव is "sambhav", अंदर is "andar".
                let next = index + 1 < syllables.count ? syllables[index + 1].onset : ""
                out += labials.contains(next.first ?? " ") ? "m" : "n"
            } else {
                out += syllable.nasal
            }
        }
        return out
    }

    private static let independentVowels: [Unicode.Scalar: Vowel] = [
        "अ": .a, "आ": .aa,
        "इ": .i, "ई": .ii,
        "उ": .u, "ऊ": .uu,
        "ऋ": .ri, "ॠ": .ri,
        "ऍ": .e, "ए": .e, "ऎ": .e, "ऐ": .ai,
        "ऑ": .o, "ओ": .o, "ऒ": .o, "औ": .au,
    ]

    private static let matras: [Unicode.Scalar: Vowel] = [
        "\u{093E}": .aa,
        "\u{093F}": .i, "\u{0940}": .ii,
        "\u{0941}": .u, "\u{0942}": .uu,
        "\u{0943}": .ri, "\u{0944}": .ri,
        "\u{0945}": .e, "\u{0946}": .e, "\u{0947}": .e, "\u{0948}": .ai,
        "\u{0949}": .o, "\u{094A}": .o, "\u{094B}": .o, "\u{094C}": .au,
    ]

    private static let consonants: [Unicode.Scalar: String] = [
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
        "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
        "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
        "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
        "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m",
        "य": "y", "र": "r", "ऱ": "r", "ल": "l", "ळ": "l", "व": "v",
        "श": "sh", "ष": "sh", "स": "s", "ह": "h",
        // The precomposed nukta letters, which arrive as one code point rather
        // than as a base plus U+093C.
        "\u{0958}": "q", "\u{0959}": "kh", "\u{095A}": "gh", "\u{095B}": "z",
        "\u{095C}": "r", "\u{095D}": "rh", "\u{095E}": "f", "\u{095F}": "y",
    ]

    /// What a following U+093C turns the base consonant into.
    private static let nuktaForms: [Unicode.Scalar: String] = [
        "क": "q", "ख": "kh", "ग": "gh", "ज": "z",
        "ड": "r", "ढ": "rh", "फ": "f", "य": "y",
    ]

    /// Devanagari that is not part of a syllable: digits, danda, om.
    private static let standalone: [Unicode.Scalar: String] = [
        "।": ".", "॥": ".",
        "०": "0", "१": "1", "२": "2", "३": "3", "४": "4",
        "५": "5", "६": "6", "७": "7", "८": "8", "९": "9",
        "ॐ": "om", "ऽ": "",
    ]
}
