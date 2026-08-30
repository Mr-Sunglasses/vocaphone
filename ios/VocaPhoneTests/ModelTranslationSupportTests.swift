import Foundation
import Testing

struct ModelTranslationSupportTests {

    private let canary: Set<String> = ["en", "de", "es", "fr"]
    private let whisper: Set<String> = ["en"]

    /// The capability matrix is the whole feature. Getting it wrong in the
    /// permissive direction is what produced the belief that any model can be
    /// asked for any output language.
    @Test func onlyTheTwoModelsThatCanTranslateClaimTo() throws {
        func targets(_ id: String) throws -> Set<String> {
            try #require(LocalModelCatalog.descriptor(for: id)).translationTargets
        }

        // Canary is a speech-translation model across the languages it lists.
        #expect(try targets("canary-180m-flash") == canary)
        // Whisper's translate task has exactly one trained target.
        #expect(try targets("openai_whisper-small_216MB") == whisper)
        // An English-only build has nothing to translate from.
        #expect(try targets("moonshine-tiny-en").isEmpty)
        // The transducers and CTC models transcribe and nothing else. Parakeet
        // v3 is the one people expect to translate because it is multilingual.
        #expect(try targets("parakeet-tdt-0.6b-v3").isEmpty)
        #expect(try targets("sense-voice").isEmpty)
        #expect(try targets("dolphin-small-ctc").isEmpty)
    }

    @Test func offIsAlwaysSelectableAndATargetOnlyWhereTrained() {
        #expect(ModelTranslationSupport.isSelectable(ModelTranslationSupport.off, targets: []))
        #expect(ModelTranslationSupport.isSelectable(.german, targets: canary))
        #expect(!ModelTranslationSupport.isSelectable(.hindi, targets: canary))
        // Whisper into English, and nothing else. Russian here is the exact
        // request that used to appear to work.
        #expect(ModelTranslationSupport.isSelectable(.english, targets: whisper))
        #expect(!ModelTranslationSupport.isSelectable(.russian, targets: whisper))
    }

    /// A target picked under Canary and left stored while the user switches to
    /// Parakeet must not survive as a request no engine can honour.
    @Test func aStaleTargetFallsBackToNoTranslation() {
        #expect(ModelTranslationSupport.resolve(.german, targets: []) == ModelTranslationSupport.off)
        #expect(ModelTranslationSupport.resolve(.german, targets: canary) == .german)
    }

    /// "auto" is a language to the engines, so absence has to reach them empty.
    @Test func theEngineTargetIsACodeOrNothingAtAll() {
        #expect(ModelTranslationSupport.target(.german, targets: canary) == "de")
        #expect(ModelTranslationSupport.target(ModelTranslationSupport.off, targets: canary) == "")
        #expect(ModelTranslationSupport.target(.german, targets: []) == "")
    }

    @Test func theRowSaysWhichOfTheThreeStatesItIsIn() {
        #expect(
            ModelTranslationSupport.summary(.german, targets: []) == "Not supported by this model"
        )
        #expect(ModelTranslationSupport.summary(ModelTranslationSupport.off, targets: canary) == "Off")
        #expect(ModelTranslationSupport.summary(.german, targets: canary) == "German")
        // Stored but unhonourable reads as Off, because Off is what happens.
        #expect(ModelTranslationSupport.summary(.hindi, targets: canary) == "Off")
        // A gateway has no local model to blame, and the fix is another screen.
        #expect(
            ModelTranslationSupport.summary(.german, targets: [], onDevice: false)
                == "Needs an on-device model"
        )
    }

    @Test func anUnsupportedModelExplainsThatTheLanguageRowNeverTranslated() {
        let none = ModelTranslationSupport.restriction([], onDevice: true)
        #expect(none?.contains("cannot translate") == true)
        #expect(none?.contains("never translated speech") == true)

        let supported = ModelTranslationSupport.restriction(canary, onDevice: true)
        #expect(supported?.contains("English, French, German and Spanish") == true)

        // Translation is an on-device feature; the gateway protocol has no field
        // for it, so saying so beats greying rows with no reason.
        let gateway = ModelTranslationSupport.restriction(canary, onDevice: false)
        #expect(gateway?.contains("runs on this phone only") == true)
    }

    /// The one way this setting can be wrong without looking wrong. Canary is
    /// told what it is translating from, so Automatic resolves to English and a
    /// German speaker is translated out of a language they never spoke.
    @Test func aModelThatCannotDetectTheSourceSaysSoWhileTheSourceIsAutomatic() {
        let warned = ModelTranslationSupport.restriction(
            canary,
            onDevice: true,
            needsExplicitSource: true,
            sourceIsAutomatic: true
        )
        #expect(warned?.contains("cannot work out what you are speaking") == true)
        #expect(warned?.contains("as though you had spoken English") == true)

        // An explicit spoken language is the fix, so there is nothing to warn about.
        let named = ModelTranslationSupport.restriction(
            canary,
            onDevice: true,
            needsExplicitSource: true,
            sourceIsAutomatic: false
        )
        #expect(named?.contains("cannot work out") == false)

        // Whisper detects the language and then translates, so Automatic is fine.
        let detecting = ModelTranslationSupport.restriction(
            whisper,
            onDevice: true,
            needsExplicitSource: false,
            sourceIsAutomatic: true
        )
        #expect(detecting?.contains("cannot work out") == false)
    }

    /// Only Canary is told its source language; nothing else needs one.
    @Test func onlyCanaryNeedsTheSpokenLanguageNamed() throws {
        func needsSource(_ id: String) throws -> Bool {
            try #require(LocalModelCatalog.descriptor(for: id)).translationNeedsExplicitSource
        }
        #expect(try needsSource("canary-180m-flash"))
        #expect(try !needsSource("openai_whisper-small_216MB"))
        #expect(try !needsSource("parakeet-tdt-0.6b-v3"))
    }

    @Test func canaryOnAutomaticIsLabelledAsNeedingASpokenLanguage() {
        #expect(
            ModelTranslationSupport.summary(
                .german,
                targets: canary,
                needsExplicitSource: true,
                sourceIsAutomatic: true
            ) == "German · set Language first"
        )
        #expect(
            ModelTranslationSupport.summary(
                .german,
                targets: canary,
                needsExplicitSource: true,
                sourceIsAutomatic: false
            ) == "German"
        )
    }

    @Test func translationSearchDoesNotFindDontTranslateByTypingAutomatic() {
        #expect(
            !ModelTranslationSupport.matchesQuery(
                "automatic",
                language: ModelTranslationSupport.off,
                translating: true
            )
        )
        #expect(
            !ModelTranslationSupport.matchesQuery(
                "auto",
                language: ModelTranslationSupport.off,
                translating: true
            )
        )
        #expect(
            ModelTranslationSupport.matchesQuery(
                "don't",
                language: ModelTranslationSupport.off,
                translating: true
            )
        )
        #expect(
            ModelTranslationSupport.matchesQuery(
                "off",
                language: ModelTranslationSupport.off,
                translating: true
            )
        )
    }

    /// Both clients must reach the same verdict, or the keyboard and the app
    /// disagree about what the user may pick.
    @Test func theRulesMatchTheAndroidImplementation() {
        #expect(ModelTranslationSupport.isSupported(canary))
        #expect(!ModelTranslationSupport.isSupported([]))
        #expect(ModelTranslationSupport.off == .automatic)
    }
}
