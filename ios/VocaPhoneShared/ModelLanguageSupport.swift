import Foundation
@preconcurrency import VocaPhoneSharedKMP

/// Which languages the loaded model can actually be asked for.
///
/// Coverage is the whole test. A model trained on other languages returns
/// nothing, so those stay disabled rather than hidden, and the reason stays
/// visible instead of the setting appearing to have gone missing.
///
/// Whether the model detects the language itself is a separate question from
/// whether it covers one. It used to collapse the picker to Automatic, which
/// left a 25-language model looking like it spoke none of them, and left the
/// writing-style pass with no language to punctuate by: those decoders report
/// nothing back, so "auto" resolved to the empty string and Cyrillic came back
/// finished with Latin full stops. The languages such a model covers are
/// offered, and `restriction` says exactly what picking one does and does not do.
///
/// Mirrors `ModelLanguageSupport.kt` on Android. Lives in the shared framework
/// because the keyboard extension has its own language menu and has to reach the
/// same conclusion as the containing app.
enum ModelLanguageSupport {

    private static func modelLanguageCodes(_ languages: Set<String>) -> String {
        languages.sorted().joined(separator: "\n")
    }

    /// An explicit selection is the output contract. The engine's reported
    /// language is useful only for Automatic; allowing it to replace a selected
    /// language makes the writing-style pass choose punctuation for another
    /// script even though the decoder was pinned to the user's selection.
    static func transcriptLanguage(requested: String, reported: String) -> String {
        LanguagePolicy.shared.transcriptLanguage(
            requested: requested,
            reported: reported,
            automaticLanguage: TranscriptionLanguage.automatic.rawValue
        )
    }

    /// The language the finished transcript is actually written in.
    ///
    /// `translateTo` wins outright when set, and that is the whole point of the
    /// overload: with translation on, the spoken language governs the decoder
    /// while the target governs the text, and it is the text the writing styles
    /// punctuate. Styling translated German by the Hindi that was spoken would
    /// end a Latin sentence with a danda. Empty means no translation, which
    /// leaves `transcriptLanguage` answering exactly as before.
    static func outputLanguage(requested: String, reported: String, translateTo: String) -> String {
        LanguagePolicy.shared.outputLanguage(
            requested: requested,
            reported: reported,
            translateTo: translateTo,
            automaticLanguage: TranscriptionLanguage.automatic.rawValue
        )
    }

    /// `modelLanguages` empty means nothing was claimed — an older gateway
    /// build, no model selected, or one the user imported. Nothing is disabled
    /// then: a client that has not been told must never lock the user out.
    ///
    /// Whether the model detects the language itself is deliberately not an
    /// argument here. It changes what the choice means, not which choices exist,
    /// and `restriction` is where that difference is spelled out.
    static func isSelectable(
        _ language: TranscriptionLanguage,
        modelLanguages: Set<String>
    ) -> Bool {
        LanguagePolicy.shared.isSelectable(
            language: language.rawValue,
            automaticLanguage: TranscriptionLanguage.automatic.rawValue,
            modelLanguageCodes: modelLanguageCodes(modelLanguages)
        )
    }

    /// The language to actually send. A stored choice goes stale when the gateway
    /// switches models, and sending it anyway produces the exact failure this
    /// exists to prevent, so it falls back to Automatic.
    static func resolve(
        _ selected: TranscriptionLanguage,
        modelLanguages: Set<String>
    ) -> TranscriptionLanguage {
        TranscriptionLanguage(
            rawValue: LanguagePolicy.shared.resolve(
                selected: selected.rawValue,
                automaticLanguage: TranscriptionLanguage.automatic.rawValue,
                modelLanguageCodes: modelLanguageCodes(modelLanguages)
            )
        ) ?? .automatic
    }

    /// What the picker's choice does and does not do here.
    ///
    /// Never nil any more: even an unrestricted model needs the sentence saying
    /// that this row is the language being spoken rather than the language
    /// wanted back. The return type stays optional so callers that already
    /// handle absence keep compiling.
    ///
    /// `onDevice` only changes which model the sentence blames, but pointing a
    /// user at their gateway when the constraint comes from the model on their
    /// phone sends them to the wrong screen.
    ///
    /// `canTranslate` adds the sentence that says what this row is not. Whisper
    /// takes its output language from a token forced into the decoder, so
    /// picking a language nobody is speaking makes it emit that language
    /// anyway — untrained behaviour that reads as translation and is the single
    /// most common misreading of this screen. The sentence is unconditional
    /// because the misreading survives being right about one model: someone who
    /// learned the trick on Whisper carries it to Parakeet, where the pick is
    /// discarded entirely.
    static func restriction(
        modelLanguages: Set<String>,
        detectsLanguageAutomatically: Bool,
        canTranslate: Bool,
        onDevice: Bool = false
    ) -> String? {
        LanguagePolicy.shared.restriction(
            modelLanguageCodes: modelLanguageCodes(modelLanguages),
            detectsLanguageAutomatically: detectsLanguageAutomatically,
            canTranslate: canTranslate,
            onDevice: onDevice
        )
    }
}
