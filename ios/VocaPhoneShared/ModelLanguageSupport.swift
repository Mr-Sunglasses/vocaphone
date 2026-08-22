import Foundation

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

    /// An explicit selection is the output contract. The engine's reported
    /// language is useful only for Automatic; allowing it to replace a selected
    /// language makes the writing-style pass choose punctuation for another
    /// script even though the decoder was pinned to the user's selection.
    static func transcriptLanguage(requested: String, reported: String) -> String {
        requested == TranscriptionLanguage.automatic.rawValue ? reported : requested
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
        if language == .automatic { return true }
        if modelLanguages.isEmpty { return true }
        return modelLanguages.contains(language.rawValue)
    }

    /// The language to actually send. A stored choice goes stale when the gateway
    /// switches models, and sending it anyway produces the exact failure this
    /// exists to prevent, so it falls back to Automatic.
    static func resolve(
        _ selected: TranscriptionLanguage,
        modelLanguages: Set<String>
    ) -> TranscriptionLanguage {
        isSelectable(selected, modelLanguages: modelLanguages) ? selected : .automatic
    }

    /// Why the picker is restricted, or nil when it is not.
    ///
    /// `onDevice` only changes which model the sentence blames, but pointing a
    /// user at their gateway when the constraint comes from the model on their
    /// phone sends them to the wrong screen.
    static func restriction(
        modelLanguages: Set<String>,
        detectsLanguageAutomatically: Bool,
        onDevice: Bool = false
    ) -> String? {
        let owner = onDevice ? "The on-device model" : "Your gateway's model"
        var coverage: String?
        if !modelLanguages.isEmpty {
            let noun = modelLanguages.count == 1 ? "language" : "languages"
            coverage = """
            \(owner) covers \(modelLanguages.count) \(noun). \
            The rest need a different model.
            """
        }
        guard detectsLanguageAutomatically else { return coverage }
        // Said plainly rather than by disabling the rows: this model decides the
        // language from the audio, and the pick only tells the app how to
        // punctuate what comes back.
        let detection = """
        \(owner) works out the spoken language itself, so picking one here does \
        not pin the decoder. It sets the language the transcript is punctuated \
        and formatted in, which is what short phrases get wrong.
        """
        return [coverage, detection].compactMap { $0 }.joined(separator: " ")
    }
}
