import Foundation

/// Which languages a model can *translate into*, as opposed to transcribe.
///
/// This is a different question from `ModelLanguageSupport`, and conflating the
/// two is what this file exists to stop. Transcription coverage asks what the
/// decoder can understand; translation coverage asks what it was trained to
/// emit for speech in some other language. Almost nothing on a phone can do the
/// second, and the two models that can do it in opposite directions:
///
/// - **Canary** is a speech-translation model proper. Its config carries a
///   source and a target language, and it was trained on the pairs between
///   English, German, Spanish and French.
/// - **Whisper** translates *into English only*. That is the translate task,
///   roughly a fifth of its training data, and no other target was ever
///   trained. Asking it for another target is not a smaller version of the same
///   feature; it is nothing at all.
///
/// Every other family — the transducers, the CTC models, Moonshine, Paraformer
/// — transcribes what it heard and has no mechanism to do anything else.
///
/// A word on the failure this replaces. Whisper picks its output language from
/// a token forced into the decoder before the first word, so selecting a
/// language the speaker is not speaking makes it emit that language anyway: it
/// satisfies the forced token the only way it can, by rendering the meaning it
/// heard. That looks like translation and is occasionally even good, but it is
/// untrained behaviour that transliterates, reverts mid-sentence and drops
/// clauses, and no transducer can imitate it. Translation is a request the
/// model either supports or does not.
///
/// Mirrors `ModelTranslationSupport.kt` on Android.
enum ModelTranslationSupport {

    /// `.automatic` is how "do not translate" is stored. The picker needs a row
    /// for it, the setting needs a default, and reusing the language enum keeps
    /// one wire vocabulary instead of two.
    static let off: TranscriptionLanguage = .automatic

    /// What the `off` row is called in the picker.
    ///
    /// Not "Automatic", which is the shared enum's own label and describes
    /// language detection — the opposite of what choosing it here means. The
    /// settings row says "Off" instead, because a row reading "Don't translate"
    /// next to the words "Translate to" reads as a double negative.
    static let offLabel = "Don't translate"

    /// Whether this model can translate at all, and so whether to offer the row.
    static func isSupported(_ targets: Set<String>) -> Bool { !targets.isEmpty }

    static func isSelectable(_ language: TranscriptionLanguage, targets: Set<String>) -> Bool {
        language == off || targets.contains(language.rawValue)
    }

    /// The target to actually use. A stored choice goes stale the moment the
    /// user switches models — from Canary to Parakeet, or to a gateway — and
    /// silently translating nothing is far better than a request the engine
    /// cannot honour.
    static func resolve(
        _ selected: TranscriptionLanguage,
        targets: Set<String>
    ) -> TranscriptionLanguage {
        isSelectable(selected, targets: targets) ? selected : off
    }

    /// The value the engines take: a language code, or empty for no
    /// translation. Engines test this for emptiness, so "auto" must never reach
    /// them — it would read as a language rather than as its absence.
    static func target(_ selected: TranscriptionLanguage, targets: Set<String>) -> String {
        let resolved = resolve(selected, targets: targets)
        return resolved == off ? "" : resolved.rawValue
    }

    /// What the picked target is called in a settings row.
    ///
    /// "Off" rather than "Automatic": the shared enum's own label describes
    /// language detection, which is the opposite of what this row's default
    /// means.
    ///
    /// `onDevice` separates the two ways this can be unavailable. Blaming the
    /// model is only right when there is one: a gateway has no local model at
    /// all, and the fix is a different screen.
    static func summary(
        _ selected: TranscriptionLanguage,
        targets: Set<String>,
        onDevice: Bool = true
    ) -> String {
        guard isSupported(targets) else {
            return onDevice ? "Not supported by this model" : "Needs an on-device model"
        }
        let resolved = resolve(selected, targets: targets)
        return resolved == off ? "Off" : resolved.displayName
    }

    /// Why the picker is limited, or nil when it is not.
    ///
    /// The unsupported case is the important one. It is the only place the app
    /// can explain that the language row above never translated anything, which
    /// is the belief people arrive with after Whisper appeared to do it.
    static func restriction(
        _ targets: Set<String>,
        onDevice: Bool,
        needsExplicitSource: Bool = false,
        sourceIsAutomatic: Bool = false
    ) -> String? {
        guard onDevice else {
            return """
            Translation runs on this phone only. Your gateway transcribes speech \
            in the language it was spoken.
            """
        }
        guard isSupported(targets) else {
            return """
            This model transcribes what it hears and cannot translate. Canary \
            translates between English, German, Spanish and French; the \
            multilingual Whisper models translate into English. Picking a \
            language above never translated speech — it only tells the model \
            which language to expect.
            """
        }
        // Sorted by the name shown, not by the code behind it: "German,
        // English, Spanish and French" is what sorting de/en/es/fr produces.
        let names = targets
            .compactMap { TranscriptionLanguage(rawValue: $0)?.displayName }
            .sorted()
        let list: String
        if names.count <= 1 {
            list = names.joined()
        } else {
            list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        let coverage = """
        This model translates into \(list). Speech in any other language it \
        covers is translated into your pick; the language above stays what you \
        are speaking.
        """
        // The one way this setting can be wrong without looking wrong. Canary
        // is told what it is translating from, so Automatic resolves to English
        // and anyone speaking something else is translated out of a language
        // they never spoke.
        guard needsExplicitSource, sourceIsAutomatic else { return coverage }
        return coverage + """
         This model cannot work out what you are speaking, so set Language to \
        your own language first: on Automatic it translates as though you had \
        spoken English.
        """
    }
}
