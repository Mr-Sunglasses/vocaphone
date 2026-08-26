import Foundation
import Testing

struct ModelLanguageSupportTests {
    @Test func explicitLanguageRemainsTheTranscriptOutputContract() {
        #expect(ModelLanguageSupport.transcriptLanguage(requested: "hi", reported: "en") == "hi")
        #expect(ModelLanguageSupport.transcriptLanguage(requested: "en", reported: "hi") == "en")
        #expect(ModelLanguageSupport.transcriptLanguage(requested: "auto", reported: "hi") == "hi")
        #expect(ModelLanguageSupport.transcriptLanguage(requested: "auto", reported: "") == "")
    }

    private let dolphin: Set<String> = ["hi", "bn", "ta", "zh", "ja"]
    private let englishOnly: Set<String> = ["en"]

    /// Coverage is the only test. An auto-detecting model still knows exactly
    /// which languages it was trained on, and hiding them made a 25-language
    /// Parakeet look like it spoke none of them.
    @Test func aModelOffersExactlyWhatItCoversDetectedOrNot() {
        #expect(ModelLanguageSupport.isSelectable(.automatic, modelLanguages: dolphin))
        #expect(ModelLanguageSupport.isSelectable(.hindi, modelLanguages: dolphin))
        #expect(!ModelLanguageSupport.isSelectable(.french, modelLanguages: dolphin))
        #expect(ModelLanguageSupport.isSelectable(.english, modelLanguages: englishOnly))
        #expect(!ModelLanguageSupport.isSelectable(.hindi, modelLanguages: englishOnly))
    }

    /// Older gateway, no model selected, or an imported one. Being uninformed
    /// must not look like being unsupported.
    @Test func anUnknownGatewayNeverLocksThePicker() {
        // Output-script rows are excluded rather than the rule being weakened.
        // "Almost every model transcribes Hindi" is what makes silence a yes;
        // nothing about that carries over to Roman Hinglish, which one model
        // produces and every other model would answer with Devanagari.
        for language in TranscriptionLanguage.allCases where !language.isOutputScript {
            #expect(
                ModelLanguageSupport.isSelectable(language, modelLanguages: []),
                "\(language) must stay selectable when the gateway made no claim"
            )
        }
    }

    @Test func anOutputScriptIsOfferedOnlyWhereItIsClaimedOutright() {
        let roman = TranscriptionLanguage.hinglishRoman
        #expect(!ModelLanguageSupport.isSelectable(roman, modelLanguages: []))
        #expect(!ModelLanguageSupport.isSelectable(roman, modelLanguages: ["hi", "en"]))
        #expect(ModelLanguageSupport.isSelectable(roman, modelLanguages: [roman.rawValue]))
    }

    /// The user picked Hindi, then switched the gateway to an English-only model.
    /// Sending "hi" anyway is exactly the failure this prevents.
    @Test func aStaleSelectionFallsBackToAutomatic() {
        #expect(ModelLanguageSupport.resolve(.hindi, modelLanguages: englishOnly) == .automatic)
        #expect(ModelLanguageSupport.resolve(.hindi, modelLanguages: dolphin) == .hindi)
        #expect(ModelLanguageSupport.resolve(.hindi, modelLanguages: []) == .hindi)
    }

    @Test func aCoverageLimitIsSpelledOutWheneverThereIsOne() {
        let unclaimed = ModelLanguageSupport.restriction(
            modelLanguages: [], detectsLanguageAutomatically: false, canTranslate: false
        )
        #expect(unclaimed?.contains("covers") == false)
        let limited = ModelLanguageSupport.restriction(
            modelLanguages: dolphin, detectsLanguageAutomatically: false, canTranslate: false
        )
        #expect(limited?.contains("\(dolphin.count) languages") == true)
    }

    /// The picker used to say nothing at all for an unrestricted model, which is
    /// exactly the case — a multilingual Whisper — where someone picks Russian,
    /// speaks English, and concludes the app translates. It never did: Whisper
    /// forces the language token and renders the meaning it heard in that
    /// script, untrained and unreliable.
    @Test func everyModelSaysTheLanguageRowIsNotATranslationSetting() {
        for detects in [false, true] {
            let sentence = ModelLanguageSupport.restriction(
                modelLanguages: [], detectsLanguageAutomatically: detects, canTranslate: false
            )
            #expect(sentence?.contains("not the language you want back") == true)
            #expect(sentence?.contains("cannot translate") == true)
        }
        let canary = ModelLanguageSupport.restriction(
            modelLanguages: ["en", "de", "es", "fr"],
            detectsLanguageAutomatically: false,
            canTranslate: true,
            onDevice: true
        )
        #expect(canary?.contains("use Translate to") == true)
        #expect(canary?.contains("cannot translate") == false)
    }

    /// With translation on, two languages are in play and only one of them is
    /// the one on screen. The styler punctuates by script, so it has to be given
    /// the target.
    @Test func theOutputLanguageIsTheTranslationTargetWhenTranslating() {
        #expect(
            ModelLanguageSupport.outputLanguage(
                requested: "hi", reported: "hi", translateTo: "de"
            ) == "de"
        )
        #expect(
            ModelLanguageSupport.outputLanguage(
                requested: "auto", reported: "hi", translateTo: "de"
            ) == "de"
        )
        #expect(
            ModelLanguageSupport.outputLanguage(
                requested: "hi", reported: "en", translateTo: ""
            ) == "hi"
        )
        #expect(
            ModelLanguageSupport.outputLanguage(
                requested: "auto", reported: "hi", translateTo: ""
            ) == "hi"
        )
    }

    /// The sentence has to say both things: the choice is real for punctuation,
    /// and it is not a decoder setting. Promising either half alone is how the
    /// picker starts lying about what the model does.
    @Test func anAutoDetectingModelSaysWhatPickingALanguageDoes() {
        let detected = ModelLanguageSupport.restriction(
            modelLanguages: dolphin, detectsLanguageAutomatically: true, canTranslate: false
        )
        #expect(detected?.contains("\(dolphin.count) languages") == true)
        #expect(detected?.contains("does not pin the decoder") == true)
        #expect(detected?.contains("punctuated") == true)
        let unclaimed = ModelLanguageSupport.restriction(
            modelLanguages: [], detectsLanguageAutomatically: true, canTranslate: false
        )
        #expect(unclaimed?.contains("does not pin the decoder") == true)
        let local = ModelLanguageSupport.restriction(
            modelLanguages: dolphin,
            detectsLanguageAutomatically: true,
            canTranslate: false,
            onDevice: true
        )
        #expect(local?.contains("The on-device model") == true)
    }

    /// Both clients must reach the same verdict, or the keyboard and the app
    /// disagree about what the user may pick.
    @Test func theRulesMatchTheAndroidImplementation() {
        #expect(ModelLanguageSupport.isSelectable(.automatic, modelLanguages: []))
        #expect(ModelLanguageSupport.isSelectable(.english, modelLanguages: []))
        #expect(ModelLanguageSupport.isSelectable(.russian, modelLanguages: LocalModelLanguages.parakeetV3))
        #expect(!ModelLanguageSupport.isSelectable(.hindi, modelLanguages: LocalModelLanguages.parakeetV3))
    }
}

/// What the UI shows must be what dictation does. The stored choice is kept, but
/// a chip reading "HI" while Automatic is what actually happens is the interface
/// lying about the result.
struct EffectiveLanguageTests {
    @Test func theDisplayedLanguageIsTheOneThatWillBeUsed() {
        KeyboardPreferences.transcriptionLanguage = .hindi
        KeyboardPreferences.modelLanguages = ["en"]
        KeyboardPreferences.modelDetectsLanguage = false
        #expect(KeyboardPreferences.effectiveTranscriptionLanguage == .automatic)

        // The stored preference survives and returns once a model supports it.
        #expect(KeyboardPreferences.transcriptionLanguage == .hindi)
        KeyboardPreferences.modelLanguages = ["en", "hi"]
        #expect(KeyboardPreferences.effectiveTranscriptionLanguage == .hindi)
    }
}
