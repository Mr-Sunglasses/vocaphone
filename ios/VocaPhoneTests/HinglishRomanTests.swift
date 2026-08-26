import Foundation
import Testing

/// The iOS half of Roman Hinglish, and the parity check that keeps it the same
/// feature on both phones.
///
/// The romanizer and the normalizer are ports, so most of these cases are the
/// Kotlin cases restated: `DevanagariRomanizerTest.kt` and
/// `HinglishNormalizerTest.kt`. Restated rather than shared, because the point is
/// that two independent implementations agree — a shared fixture would only
/// prove the fixture parses.
struct HinglishRomanTests {

    // MARK: - Romanization

    @Test func implicitVowelsAreDroppedAtTheEndOfAWord() {
        // Without this every word gains a syllable: "gharaa", "kalaa", "ekaa".
        #expect(DevanagariRomanizer.romanize("घर") == "ghar")
        #expect(DevanagariRomanizer.romanize("कल") == "kal")
        #expect(DevanagariRomanizer.romanize("एक") == "ek")
        #expect(DevanagariRomanizer.romanize("आज") == "aaj")
    }

    @Test func implicitVowelsAreDroppedMidWordBeforeAWrittenVowel() {
        #expect(DevanagariRomanizer.romanize("करना") == "karna")
        #expect(DevanagariRomanizer.romanize("करनी") == "karni")
        #expect(DevanagariRomanizer.romanize("देखना") == "dekhna")
    }

    @Test func implicitVowelsSurviveWhereTheNextSyllableHasNoWrittenVowel() {
        // समझ is the counterexample: ज carries no written vowel either, so the
        // schwa on म is pronounced and "samjh" is wrong.
        #expect(DevanagariRomanizer.romanize("समझ") == "samajh")
        #expect(DevanagariRomanizer.romanize("भारत") == "bhaarat")
    }

    @Test func theFirstSyllableNeverLosesItsImplicitVowel() {
        // Without the guard पता collapses to "pta", which is unreadable.
        #expect(DevanagariRomanizer.romanize("पता") == "pata")
        #expect(DevanagariRomanizer.romanize("बताना") == "bataana")
    }

    @Test func longVowelsShortenOnlyAtTheEndOfAWord() {
        #expect(DevanagariRomanizer.romanize("ठीक") == "theek")
        #expect(DevanagariRomanizer.romanize("कभी") == "kabhi")
        #expect(DevanagariRomanizer.romanize("काम") == "kaam")
        #expect(DevanagariRomanizer.romanize("दूसरा") == "doosra")
    }

    @Test func aTrailingNasalDoesNotMakeTheVowelBeforeItNonFinal() {
        #expect(DevanagariRomanizer.romanize("नहीं") == "nahin")
        #expect(DevanagariRomanizer.romanize("हूँ") == "hun")
        #expect(DevanagariRomanizer.romanize("मैं") == "main")
        #expect(DevanagariRomanizer.romanize("हैं") == "hain")
    }

    @Test func anusvaraIsMBeforeALipConsonantAndNEverywhereElse() {
        #expect(DevanagariRomanizer.romanize("संभव") == "sambhav")
        #expect(DevanagariRomanizer.romanize("अंदर") == "andar")
    }

    @Test func conjunctsKeepBothConsonantsAndNoVowelBetweenThem() {
        #expect(DevanagariRomanizer.romanize("क्या") == "kya")
        #expect(DevanagariRomanizer.romanize("नमस्ते") == "namaste")
        #expect(DevanagariRomanizer.romanize("कुछ") == "kuchh")
    }

    @Test func nuktaLettersTakeTheirOwnSounds() {
        #expect(DevanagariRomanizer.romanize("ज़रूर") == "zaroor")
        #expect(DevanagariRomanizer.romanize("फ़ोन") == "fon")
        #expect(DevanagariRomanizer.romanize("बड़ा") == "bara")
    }

    @Test func devanagariDigitsAndDandaBecomeTheirLatinEquivalents() {
        #expect(DevanagariRomanizer.romanize("१२३") == "123")
        #expect(DevanagariRomanizer.romanize("ठीक।") == "theek.")
    }

    @Test func aCodeSwitchedSentenceKeepsItsEnglishHalfVerbatim() {
        #expect(
            DevanagariRomanizer.romanize("आज मुझे office में एक important meeting attend करनी है")
                == "aaj mujhe office men ek important meeting attend karni hai"
        )
    }

    // MARK: - Normalization

    @Test func devanagariNeverSurvives() {
        for spoken in [
            "आज मुझे office में एक important meeting attend करनी है",
            "कल मेरी client के साथ deployment meeting है",
            "सब कुछ ठीक है।",
            "मैं थोड़ी देर में call करता हूँ",
        ] {
            let normalized = HinglishNormalizer.normalize(spoken)
            #expect(!HinglishNormalizer.containsDevanagari(normalized), "leaked: \(normalized)")
        }
    }

    @Test func devanagariIsTransliteratedRatherThanDeleted() {
        // The failure this rules out is the quiet one: dropping the script loses
        // words the user said, and the transcript still looks like a clean
        // sentence.
        let normalized = HinglishNormalizer.normalize("मुझे कल जाना है")
        #expect(normalized.split(separator: " ").count == 4)
        #expect(normalized.contains("mujhe"))
    }

    @Test func anAlreadyRomanTranscriptIsLeftAlone() {
        let roman = "Kal meri client ke saath deployment meeting hai."
        #expect(HinglishNormalizer.normalize(roman) == roman)
    }

    @Test func englishWordsSpokenInEnglishArePreservedVerbatim() {
        let normalized = HinglishNormalizer.normalize(
            "मुझे server पर नया deployment करना है और database migrate करना है"
        )
        for word in ["server", "deployment", "database", "migrate"] {
            #expect(normalized.contains(word), "lost \(word) in \(normalized)")
        }
    }

    @Test func anEnglishHomographOfAHindiSpellingIsNotRewritten() {
        // "men" is में out of the transliterator and the English plural
        // everywhere else. Only the first may become "mein".
        #expect(
            HinglishNormalizer.normalize("Three men joined the call.")
                == "Three men joined the call."
        )
        #expect(HinglishNormalizer.normalize("मैं office में हूँ").contains("mein"))
    }

    @Test func protectedSpansSurviveEveryPass() {
        let cases = [
            ("docs पर जाओ https://vocahq.com/setup?ref=a_b", "https://vocahq.com/setup?ref=a_b"),
            ("मुझे mail करो at yaviral@example.com", "yaviral@example.com"),
            ("फ़ाइल है /var/log/whisper.log में", "/var/log/whisper.log"),
            ("फिर run करो git push --force-with-lease", "--force-with-lease"),
            ("@priya को tag करो #release में", "@priya"),
            ("API का response GPU पर slow है", "API"),
            ("meeting है 3:30 बजे और budget है 45,000 रुपये", "45,000"),
        ]
        for (spoken, span) in cases {
            let normalized = HinglishNormalizer.normalize(spoken)
            #expect(normalized.contains(span), "lost \(span) from \(normalized)")
        }
    }

    @Test func oneSpellingPerWordPerTheDocumentedConvention() {
        #expect(HinglishNormalizer.normalize("मुझे").contains("mujhe"))
        #expect(HinglishNormalizer.normalize("muje aana hai").contains("mujhe"))
        #expect(HinglishNormalizer.normalize("kyu nahi aaye").contains("kyun"))
        #expect(HinglishNormalizer.normalize("nahi aa raha").contains("nahin"))
        #expect(HinglishNormalizer.normalize("thik hai").contains("theek"))
    }

    @Test func heyBecomesHaiMidSentenceAndStaysHeyAsAnOpener() {
        #expect(HinglishNormalizer.normalize("Sab theek hey") == "Sab theek hai")
        #expect(HinglishNormalizer.normalize("Hey, kaise ho?") == "Hey, kaise ho?")
    }

    @Test func caseIsCarriedThroughARewrite() {
        #expect(HinglishNormalizer.normalize("Muje kal jaana hai").hasPrefix("Mujhe"))
    }

    @Test func punctuationIsTidiedWithoutInventingAny() {
        #expect(HinglishNormalizer.normalize("Haan ,   theek hai.") == "Haan, theek hai.")
        // TranscriptStyler runs after this and owns capitalization and sentence
        // endings for every language. Doing it twice would fight it.
        #expect(HinglishNormalizer.normalize("theek hai") == "theek hai")
        #expect(HinglishNormalizer.normalize("सब ठीक है ।").hasSuffix("."))
    }

    @Test func normalizingTwiceChangesNothingTheSecondTime() {
        let once = HinglishNormalizer.normalize("आज मुझे office में meeting attend करनी है")
        #expect(HinglishNormalizer.normalize(once) == once)
    }

    @Test func blankInputGivesBlankOutput() {
        #expect(HinglishNormalizer.normalize("") == "")
        #expect(HinglishNormalizer.normalize("   \n  ") == "")
    }

    @Test func eachPassCanBeTurnedOffIndependently() {
        let spoken = "muje में jaana hai"
        #expect(
            HinglishNormalizer.normalize(
                spoken,
                options: .init(
                    transliterateDevanagari: false,
                    applyRomanizedConventions: false,
                    applyGlobalConventions: false,
                    normalizePunctuation: false
                )
            ) == spoken
        )
        // Transliteration on, conventions off: the mechanical spelling stands.
        #expect(
            HinglishNormalizer
                .normalize("में", options: .init(applyRomanizedConventions: false))
                .contains("men")
        )
    }

    // MARK: - Selection

    @Test func theRomanRowNeedsAModelThatSaysSoInAsManyWords() {
        let roman = TranscriptionLanguage.hinglishRoman
        #expect(ModelLanguageSupport.isSelectable(roman, modelLanguages: [roman.rawValue]))
        #expect(!ModelLanguageSupport.isSelectable(roman, modelLanguages: ["hi", "en"]))
        // Silence is a no here, unlike every ordinary language: an unknown
        // gateway has certainly not been taught this value.
        #expect(!ModelLanguageSupport.isSelectable(roman, modelLanguages: []))
    }

    @Test func ordinaryLanguagesStillDefaultToSelectableWhenNothingIsClaimed() {
        // The rule above must not have narrowed anything else.
        #expect(ModelLanguageSupport.isSelectable(.hindi, modelLanguages: []))
        #expect(ModelLanguageSupport.isSelectable(.english, modelLanguages: []))
    }

    @Test func aStaleRomanChoiceFallsBackToAutomatic() {
        #expect(
            ModelLanguageSupport.resolve(.hinglishRoman, modelLanguages: ["hi", "en"]) == .automatic
        )
    }

    @Test func theDecoderIsAskedForHindiAndTheTranscriptStaysRoman() {
        let roman = TranscriptionLanguage.hinglishRoman.rawValue
        #expect(ModelLanguageSupport.decoderLanguage(roman) == "hi")
        #expect(ModelLanguageSupport.transcriptLanguage(requested: roman, reported: "hi") == roman)
        // No other language is routed through this mapping.
        for code in ["hi", "en", "auto", "de", ""] {
            #expect(ModelLanguageSupport.decoderLanguage(code) == code)
        }
    }

    @Test func theLabelSaysExperimentalWhereAUserWillReadIt() {
        #expect(TranscriptionLanguage.hinglishRoman.isExperimental)
        #expect(TranscriptionLanguage.hinglishRoman.isOutputScript)
        #expect(TranscriptionLanguage.hinglishRoman.detail.contains("Experimental"))
        #expect(TranscriptionLanguage.hinglishRoman.shortLabel == "Hinglish")
        #expect(TranscriptionLanguage.hinglishRoman.displayName == "Hinglish — Roman")
    }

    /// iOS ships no Hinglish model yet: WhisperKit needs a Core ML build and no
    /// verified one exists. The row must therefore be unreachable here — greyed
    /// in the picker, never selected by accident — while the layers underneath it
    /// stay in step with Android so that adding the model later is one catalog
    /// entry and not a port.
    @Test func noModelOnThisPlatformCanHonourTheRomanRowYet() {
        let roman = TranscriptionLanguage.hinglishRoman.rawValue
        #expect(LocalModelCatalog.all.allSatisfy { !$0.languageCodes.contains(roman) })
        for descriptor in LocalModelCatalog.all {
            #expect(
                !ModelLanguageSupport.isSelectable(
                    .hinglishRoman,
                    modelLanguages: descriptor.languageCodes
                )
            )
        }
    }
}
