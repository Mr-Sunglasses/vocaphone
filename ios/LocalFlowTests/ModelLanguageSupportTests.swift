import Foundation
import Testing

struct ModelLanguageSupportTests {
    private let dolphin: Set<String> = ["hi", "bn", "ta", "zh", "ja"]
    private let englishOnly: Set<String> = ["en"]

    /// Dolphin ignores the requested language, so offering Hindi promises
    /// something it cannot deliver — it returned Cyrillic for a short Hindi clip.
    @Test func aModelThatDetectsItsOwnLanguageOffersOnlyAutomatic() {
        #expect(
            ModelLanguageSupport.isSelectable(
                .automatic, modelLanguages: dolphin, detectsLanguageAutomatically: true
            )
        )
        for language in TranscriptionLanguage.allCases where language != .automatic {
            #expect(
                !ModelLanguageSupport.isSelectable(
                    language, modelLanguages: dolphin, detectsLanguageAutomatically: true
                ),
                "\(language) must not be selectable on an auto-detecting model"
            )
        }
    }

    @Test func aPinnableModelOffersExactlyWhatItCovers() {
        #expect(
            ModelLanguageSupport.isSelectable(
                .hindi, modelLanguages: dolphin, detectsLanguageAutomatically: false
            )
        )
        #expect(
            !ModelLanguageSupport.isSelectable(
                .french, modelLanguages: dolphin, detectsLanguageAutomatically: false
            )
        )
        #expect(
            !ModelLanguageSupport.isSelectable(
                .hindi, modelLanguages: englishOnly, detectsLanguageAutomatically: false
            )
        )
    }

    /// Older gateway, no model selected, or an imported one. Being uninformed
    /// must not look like being unsupported.
    @Test func anUnknownGatewayNeverLocksThePicker() {
        for language in TranscriptionLanguage.allCases {
            #expect(
                ModelLanguageSupport.isSelectable(
                    language, modelLanguages: [], detectsLanguageAutomatically: false
                ),
                "\(language) must stay selectable when the gateway made no claim"
            )
        }
    }

    /// The user picked Hindi, then switched the gateway to an English-only model.
    /// Sending "hi" anyway is exactly the failure this prevents.
    @Test func aStaleSelectionFallsBackToAutomatic() {
        #expect(
            ModelLanguageSupport.resolve(
                .hindi, modelLanguages: englishOnly, detectsLanguageAutomatically: false
            ) == .automatic
        )
        #expect(
            ModelLanguageSupport.resolve(
                .hindi, modelLanguages: dolphin, detectsLanguageAutomatically: true
            ) == .automatic
        )
        #expect(
            ModelLanguageSupport.resolve(
                .hindi, modelLanguages: dolphin, detectsLanguageAutomatically: false
            ) == .hindi
        )
        #expect(
            ModelLanguageSupport.resolve(
                .hindi, modelLanguages: [], detectsLanguageAutomatically: false
            ) == .hindi
        )
    }

    @Test func theRestrictionIsExplainedOnlyWhenThereIsOne() {
        #expect(
            ModelLanguageSupport.restriction(
                modelLanguages: [], detectsLanguageAutomatically: false
            ) == nil
        )
        let automatic = ModelLanguageSupport.restriction(
            modelLanguages: dolphin, detectsLanguageAutomatically: true
        )
        #expect(automatic?.contains("detects the language itself") == true)
        let limited = ModelLanguageSupport.restriction(
            modelLanguages: dolphin, detectsLanguageAutomatically: false
        )
        #expect(limited?.contains("\(dolphin.count) languages") == true)
    }

    /// Both clients must reach the same verdict, or the keyboard and the app
    /// disagree about what the user may pick.
    @Test func theRulesMatchTheAndroidImplementation() {
        #expect(
            ModelLanguageSupport.isSelectable(
                .automatic, modelLanguages: [], detectsLanguageAutomatically: true
            )
        )
        #expect(
            !ModelLanguageSupport.isSelectable(
                .english, modelLanguages: [], detectsLanguageAutomatically: true
            )
        )
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
