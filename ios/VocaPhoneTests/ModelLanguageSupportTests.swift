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
        for language in TranscriptionLanguage.allCases {
            #expect(
                ModelLanguageSupport.isSelectable(language, modelLanguages: []),
                "\(language) must stay selectable when the gateway made no claim"
            )
        }
    }

    /// The user picked Hindi, then switched the gateway to an English-only model.
    /// Sending "hi" anyway is exactly the failure this prevents.
    @Test func aStaleSelectionFallsBackToAutomatic() {
        #expect(ModelLanguageSupport.resolve(.hindi, modelLanguages: englishOnly) == .automatic)
        #expect(ModelLanguageSupport.resolve(.hindi, modelLanguages: dolphin) == .hindi)
        #expect(ModelLanguageSupport.resolve(.hindi, modelLanguages: []) == .hindi)
    }

    @Test func theRestrictionIsExplainedOnlyWhenThereIsOne() {
        #expect(
            ModelLanguageSupport.restriction(
                modelLanguages: [], detectsLanguageAutomatically: false
            ) == nil
        )
        let limited = ModelLanguageSupport.restriction(
            modelLanguages: dolphin, detectsLanguageAutomatically: false
        )
        #expect(limited?.contains("\(dolphin.count) languages") == true)
    }

    /// The sentence has to say both things: the choice is real for punctuation,
    /// and it is not a decoder setting. Promising either half alone is how the
    /// picker starts lying about what the model does.
    @Test func anAutoDetectingModelSaysWhatPickingALanguageDoes() {
        let detected = ModelLanguageSupport.restriction(
            modelLanguages: dolphin, detectsLanguageAutomatically: true
        )
        #expect(detected?.contains("\(dolphin.count) languages") == true)
        #expect(detected?.contains("does not pin the decoder") == true)
        #expect(detected?.contains("punctuated") == true)
        let unclaimed = ModelLanguageSupport.restriction(
            modelLanguages: [], detectsLanguageAutomatically: true
        )
        #expect(unclaimed?.contains("does not pin the decoder") == true)
        let local = ModelLanguageSupport.restriction(
            modelLanguages: dolphin, detectsLanguageAutomatically: true, onDevice: true
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
