import Foundation

/// Which languages the gateway's loaded model can actually be asked for.
///
/// Offering a language the model cannot honour is how a dictation comes back in
/// the wrong alphabet: models that detect the language themselves ignore the
/// request entirely, and a model trained on other languages returns nothing.
/// Unavailable options are disabled rather than hidden, so the reason stays
/// visible instead of the setting appearing to have gone missing.
///
/// Mirrors `ModelLanguageSupport.kt` on Android. Lives in the shared framework
/// because the keyboard extension has its own language menu and has to reach the
/// same conclusion as the containing app.
enum ModelLanguageSupport {

    /// `modelLanguages` empty means the gateway made no claim — an older build,
    /// no model selected, or one the user imported. Nothing is disabled then: a
    /// client that has not been told must never lock the user out.
    static func isSelectable(
        _ language: TranscriptionLanguage,
        modelLanguages: Set<String>,
        detectsLanguageAutomatically: Bool
    ) -> Bool {
        if language == .automatic { return true }
        if modelLanguages.isEmpty { return !detectsLanguageAutomatically }
        if detectsLanguageAutomatically { return false }
        return modelLanguages.contains(language.rawValue)
    }

    /// The language to actually send. A stored choice goes stale when the gateway
    /// switches models, and sending it anyway produces the exact failure this
    /// exists to prevent, so it falls back to Automatic.
    static func resolve(
        _ selected: TranscriptionLanguage,
        modelLanguages: Set<String>,
        detectsLanguageAutomatically: Bool
    ) -> TranscriptionLanguage {
        isSelectable(
            selected,
            modelLanguages: modelLanguages,
            detectsLanguageAutomatically: detectsLanguageAutomatically
        ) ? selected : .automatic
    }

    /// Why the picker is restricted, or nil when it is not.
    static func restriction(
        modelLanguages: Set<String>,
        detectsLanguageAutomatically: Bool
    ) -> String? {
        if detectsLanguageAutomatically {
            return """
            Your gateway's model detects the language itself, so only Automatic \
            applies. It reads full sentences well but returns the wrong alphabet \
            on short phrases.
            """
        }
        if modelLanguages.isEmpty { return nil }
        return """
        Your gateway's model covers \(modelLanguages.count) languages. \
        The rest need a different model.
        """
    }
}
