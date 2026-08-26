import Foundation

/// Presentation only. No style adds, removes or substitutes a word, and
/// numbers, times, addresses and contractions are always left as the model
/// transcribed them.
enum WritingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case raw
    case clean
    case formal
    case casual
    case veryCasual = "very_casual"
    case excited

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw: "Raw"
        case .clean: "Clean"
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very Casual"
        case .excited: "Excited"
        }
    }

    var detail: String {
        switch self {
        case .raw:
            "Exactly what the model returned, with nothing changed."
        case .clean:
            "Spacing tidied and a closing full stop. Random capitals from the model are flattened; names like VocaPhone stay."
        case .formal:
            "Sentence capitalization and a closing full stop. Mid-sentence Title Case from the model is flattened."
        case .casual:
            "Sentences kept, but no closing full stop."
        case .veryCasual:
            "All lowercase, sentences joined with commas."
        case .excited:
            "Every statement ends with an exclamation mark."
        }
    }

    /// Unstyled model output the picker examples are produced from.
    /// Clean and Formal only diverge when sentence starts are still lowercase.
    static let exampleSource = "this is VocaPhone. it is a keyboard you talk to"

    /// A short worked example, so the choice is obvious before dictating.
    var example: String {
        TranscriptStyler.apply(Self.exampleSource, style: self)
    }

    var symbolName: String {
        switch self {
        case .raw: "doc.plaintext"
        case .clean: "wand.and.stars"
        case .formal: "textformat"
        case .casual: "text.bubble"
        case .veryCasual: "textformat.abc"
        case .excited: "sparkles"
        }
    }
}

enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case arabic = "ar"
    case assamese = "as"
    case bengali = "bn"
    case bulgarian = "bg"
    case cantonese = "yue"
    case catalan = "ca"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case english = "en"
    case estonian = "et"
    case filipino = "tl"
    case finnish = "fi"
    case french = "fr"
    case german = "de"
    case greek = "el"
    case gujarati = "gu"
    case hebrew = "he"
    case hindi = "hi"
    /// Not a language: an output contract. Mixed Hindi and English, as spoken,
    /// written in one Latin script. Mirrors `TranscriptionLanguage.kt`; only a
    /// model that names this code can honour it, which `ModelLanguageSupport`
    /// enforces rather than assuming.
    case hinglishRoman = "hinglish_roman"
    case hungarian = "hu"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case kannada = "kn"
    case korean = "ko"
    case latvian = "lv"
    case lithuanian = "lt"
    case malay = "ms"
    case malayalam = "ml"
    case maltese = "mt"
    case mandarinChinese = "zh"
    case marathi = "mr"
    case nepali = "ne"
    case norwegian = "no"
    case persian = "fa"
    case polish = "pl"
    case portuguese = "pt"
    case punjabi = "pa"
    case romanian = "ro"
    case russian = "ru"
    case serbian = "sr"
    case slovak = "sk"
    case slovenian = "sl"
    case spanish = "es"
    case swahili = "sw"
    case swedish = "sv"
    case tamil = "ta"
    case telugu = "te"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case urdu = "ur"
    case vietnamese = "vi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .arabic: "Arabic"
        case .assamese: "Assamese"
        case .bengali: "Bengali"
        case .bulgarian: "Bulgarian"
        case .cantonese: "Cantonese"
        case .catalan: "Catalan"
        case .croatian: "Croatian"
        case .czech: "Czech"
        case .danish: "Danish"
        case .dutch: "Dutch"
        case .english: "English"
        case .estonian: "Estonian"
        case .filipino: "Filipino"
        case .finnish: "Finnish"
        case .french: "French"
        case .german: "German"
        case .greek: "Greek"
        case .gujarati: "Gujarati"
        case .hebrew: "Hebrew"
        case .hindi: "Hindi"
        case .hinglishRoman: "Hinglish — Roman"
        case .hungarian: "Hungarian"
        case .indonesian: "Indonesian"
        case .italian: "Italian"
        case .japanese: "Japanese"
        case .kannada: "Kannada"
        case .korean: "Korean"
        case .latvian: "Latvian"
        case .lithuanian: "Lithuanian"
        case .malay: "Malay"
        case .malayalam: "Malayalam"
        case .maltese: "Maltese"
        case .mandarinChinese: "Mandarin Chinese"
        case .marathi: "Marathi"
        case .nepali: "Nepali"
        case .norwegian: "Norwegian"
        case .persian: "Persian"
        case .polish: "Polish"
        case .portuguese: "Portuguese"
        case .punjabi: "Punjabi"
        case .romanian: "Romanian"
        case .russian: "Russian"
        case .serbian: "Serbian"
        case .slovak: "Slovak"
        case .slovenian: "Slovenian"
        case .spanish: "Spanish"
        case .swahili: "Swahili"
        case .swedish: "Swedish"
        case .tamil: "Tamil"
        case .telugu: "Telugu"
        case .thai: "Thai"
        case .turkish: "Turkish"
        case .ukrainian: "Ukrainian"
        case .urdu: "Urdu"
        case .vietnamese: "Vietnamese"
        }
    }

    /// The chip label. Derived from the code rather than switched over, so a new
    /// language is one line in the case list and not three.
    var shortLabel: String {
        switch self {
        case .automatic: "Auto"
        // The only raw value that is not a two- or three-letter code, and
        // "HINGLISH_ROMAN" on a keyboard chip is unreadable.
        case .hinglishRoman: "Hinglish"
        default: rawValue.uppercased()
        }
    }

    /// Whether this row describes an output script rather than a spoken
    /// language. See `ModelLanguageSupport.isSelectable`.
    var isOutputScript: Bool { self == .hinglishRoman }

    /// Marked in the UI so nobody mistakes it for a finished feature.
    var isExperimental: Bool { self == .hinglishRoman }

    var detail: String {
        switch self {
        case .automatic:
            "Uses the language of the model selected on your gateway."
        case .hinglishRoman:
            """
            Experimental. Writes mixed Hindi and English in the Latin alphabet, \
            as spoken. Needs the Hinglish model on this phone.
            """
        default:
            "Requires a matching multilingual or \(displayName) model on your gateway."
        }
    }
}

enum MicrophonePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case iPhone = "iphone"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .iPhone: "iPhone Microphone"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "iOS chooses the input and may use an AirPods microphone when connected."
        case .iPhone:
            "Always request the microphone built into this iPhone."
        }
    }
}

/// How tall the keyboard draws itself in portrait.
///
/// Comfort here is genuinely personal — thumb reach, hand size, and how much of
/// the host app someone wants to keep in view all pull in different directions —
/// and it is the kind of choice iOS itself does not offer, so vocaphone does.
/// ``standard`` reproduces the geometry the keyboard shipped with, so an
/// existing install notices nothing.
///
/// Landscape is deliberately not derived from this. A compact-height phone has
/// almost no room to give away, and multiplying an already-tight layout by
/// `.tall` would cover the field being typed into.
enum KeyboardHeightPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case compact
    case standard
    case tall

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .tall: "Tall"
        }
    }

    var detail: String {
        switch self {
        case .compact: "Smaller keys, so more of the app you are typing into stays visible."
        case .standard: "The balanced default, close to the system keyboard."
        case .tall: "Larger key targets, at the cost of covering more of the screen."
        }
    }
}

enum KeyboardPreferences {
    static let autoInsertKey = "autoInsertTranscripts"
    static let keyboardHeightKey = "keyboardHeight"
    static let typingSuggestionsKey = "typingSuggestionsEnabled"
    static let autocorrectKey = "autocorrectEnabled"
    static let nextWordPredictionKey = "nextWordPredictionEnabled"
    static let learnAsITypeKey = "learnAsITypeEnabled"
    static let smartPunctuationKey = "smartPunctuationEnabled"
    static let emojiSuggestionsKey = "emojiSuggestionsEnabled"
    static let keyboardHapticsKey = "keyboardHapticsEnabled"
    static let swipeTypingKey = "swipeTypingEnabled"
    static let numberRowKey = "numberRowEnabled"
    static let quickDictationKey = "quickDictationEnabled"
    static let writingStyleKey = "writingStyle"
    static let numbersAsDigitsKey = "numbersAsDigitsEnabled"
    static let transcriptionLanguageKey = "transcriptionLanguage"
    static let translateToKey = "translateTo"
    static let microphonePreferenceKey = "microphonePreference"
    static let recordingSoundsKey = "recordingSoundsEnabled"
    static let containingAppForegroundKey = "containingAppForeground"
    static let setupCompletedKey = "setupCompleted"
    /// The exact first-run page to restore if iOS terminates the app while the
    /// user is in Settings. Setup is mandatory, so a relaunch must continue the
    /// task instead of replaying Welcome or falling through to Home.
    static let onboardingStageKey = "onboardingStage"
    /// Set before onboarding opens iOS Settings for the keyboard. Unlike view
    /// state, this survives iOS reclaiming the app while Settings is in front,
    /// so the first return can reveal the confirmation action immediately.
    static let keyboardSettingsRoundTripKey = "keyboardSettingsRoundTripStarted"
    static let firstDictationKey = "hasCompletedFirstDictation"
    /// Separate from the first transcript milestone: this proves the user has
    /// seen a transcript make the complete trip through the keyboard and into a
    /// field hosted by vocaphone.
    static let keyboardPracticeKey = "hasCompletedKeyboardPractice"
    /// Lets an upgrade distinguish an existing first transcript from a new user
    /// completing a diagnostic microphone test after this key was introduced.
    static let keyboardPracticeMigrationKey = "hasMigratedKeyboardPractice"
    static let modelLanguagesKey = "gatewayModelLanguages"
    static let modelDetectsLanguageKey = "gatewayModelDetectsLanguage"
    static let recentLanguagesKey = "recentTranscriptionLanguages"

    nonisolated(unsafe) static let defaults = UserDefaults(
        suiteName: AppConfiguration.appGroupIdentifier
    )

    static var autoInsertTranscripts: Bool {
        get {
            guard let defaults else { return true }
            guard defaults.object(forKey: autoInsertKey) != nil else { return true }
            return defaults.bool(forKey: autoInsertKey)
        }
        set {
            defaults?.set(newValue, forKey: autoInsertKey)
        }
    }

    static var quickDictationEnabled: Bool {
        get {
            guard let defaults else { return true }
            guard defaults.object(forKey: quickDictationKey) != nil else { return true }
            return defaults.bool(forKey: quickDictationKey)
        }
        set {
            defaults?.set(newValue, forKey: quickDictationKey)
        }
    }

    /// Defaults to ``KeyboardHeightPreference/standard`` when absent, which is
    /// every existing install: the preference is new, and the geometry it names
    /// is the geometry those keyboards already draw.
    static var keyboardHeight: KeyboardHeightPreference {
        get {
            guard let rawValue = defaults?.string(forKey: keyboardHeightKey),
                  let preference = KeyboardHeightPreference(rawValue: rawValue)
            else { return .standard }
            return preference
        }
        set {
            defaults?.set(newValue.rawValue, forKey: keyboardHeightKey)
        }
    }

    /// Every typing-intelligence switch, each defaulting explicitly so that a
    /// keyboard running **without Full Access** — which cannot read the App
    /// Group at all — behaves the same as one that has never been configured.
    /// Suggestions in particular must work without it: a keyboard that needs
    /// Full Access to type is not a keyboard.
    static var typingSuggestionsEnabled: Bool {
        get { boolean(typingSuggestionsKey, default: true) }
        set { defaults?.set(newValue, forKey: typingSuggestionsKey) }
    }

    /// Meaningless on its own — the strip is where a correction is shown before
    /// it is applied, so autocorrect without suggestions would replace words
    /// with no warning at all. Callers read ``autocorrectIsActive``.
    static var autocorrectEnabled: Bool {
        get { boolean(autocorrectKey, default: true) }
        set { defaults?.set(newValue, forKey: autocorrectKey) }
    }

    static var autocorrectIsActive: Bool { typingSuggestionsEnabled && autocorrectEnabled }

    static var nextWordPredictionEnabled: Bool {
        get { boolean(nextWordPredictionKey, default: true) }
        set { defaults?.set(newValue, forKey: nextWordPredictionKey) }
    }

    static var learnAsITypeEnabled: Bool {
        get { boolean(learnAsITypeKey, default: true) }
        set { defaults?.set(newValue, forKey: learnAsITypeKey) }
    }

    /// Curly quotes, em dashes and ellipses. On by default, but the *field*
    /// outranks it: a code editor turns smart quotes off precisely so that a
    /// keyboard does not curl them.
    static var smartPunctuationEnabled: Bool {
        get { boolean(smartPunctuationKey, default: true) }
        set { defaults?.set(newValue, forKey: smartPunctuationKey) }
    }

    /// An emoji offered beside the word candidates while typing — "lol" offers
    /// 😂. On by default: it adds a chip the user may ignore and never changes
    /// text on its own, which is the bar for a suggestion being on.
    static var emojiSuggestionsEnabled: Bool {
        get { boolean(emojiSuggestionsKey, default: true) }
        set { defaults?.set(newValue, forKey: emojiSuggestionsKey) }
    }

    /// A no-op without Full Access, because a keyboard extension cannot reach
    /// the haptic engine without it. The Keyboard settings screen says so
    /// rather than leaving people to wonder why their keyboard is silent.
    static var keyboardHapticsEnabled: Bool {
        get { boolean(keyboardHapticsKey, default: true) }
        set { defaults?.set(newValue, forKey: keyboardHapticsKey) }
    }

    /// Off until device QA says the recogniser has earned it. A swipe engine
    /// that guesses wrong is worse than no swipe engine, because the user has
    /// to notice and undo a whole word rather than one letter.
    static var swipeTypingEnabled: Bool {
        get { boolean(swipeTypingKey, default: false) }
        set { defaults?.set(newValue, forKey: swipeTypingKey) }
    }

    static var numberRowEnabled: Bool {
        get { boolean(numberRowKey, default: false) }
        set { defaults?.set(newValue, forKey: numberRowKey) }
    }

    /// An absent key means "never set", which is the default — not `false`,
    /// which is what `UserDefaults.bool(forKey:)` would say.
    private static func boolean(_ key: String, default fallback: Bool) -> Bool {
        guard let defaults, defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    static var recordingSoundsEnabled: Bool {
        get { defaults?.bool(forKey: recordingSoundsKey) ?? false }
        set { defaults?.set(newValue, forKey: recordingSoundsKey) }
    }

    /// Whether dictated number words are written as digits — "six pm" as
    /// "6 pm". Off by default: it changes the words in a transcript rather than
    /// its formatting, which is not something to start doing to someone's text
    /// because they updated the app.
    static var numbersAsDigits: Bool {
        get { boolean(numbersAsDigitsKey, default: false) }
        set { defaults?.set(newValue, forKey: numbersAsDigitsKey) }
    }

    static var writingStyle: WritingStyle {
        get {
            guard let rawValue = defaults?.string(forKey: writingStyleKey),
                  let style = WritingStyle(rawValue: rawValue)
            else { return .casual }
            return style
        }
        set {
            defaults?.set(newValue.rawValue, forKey: writingStyleKey)
        }
    }

    /// Languages picked recently, most recent first. Shared through the App Group
    /// so the keyboard's short menu and the app agree on what to surface, and
    /// capped because the point is to keep the keyboard menu to a glance.
    static let recentLanguageLimit = 3

    static var recentTranscriptionLanguages: [TranscriptionLanguage] {
        get {
            (defaults?.stringArray(forKey: recentLanguagesKey) ?? [])
                .compactMap(TranscriptionLanguage.init(rawValue:))
        }
        set {
            defaults?.set(newValue.map(\.rawValue), forKey: recentLanguagesKey)
        }
    }

    /// Records a pick. Automatic is excluded: it is always shown first anyway, so
    /// listing it again would spend one of three scarce slots on a duplicate.
    static func noteTranscriptionLanguageUse(_ language: TranscriptionLanguage) {
        guard language != .automatic else { return }
        var recents = recentTranscriptionLanguages.filter { $0 != language }
        recents.insert(language, at: 0)
        recentTranscriptionLanguages = Array(recents.prefix(recentLanguageLimit))
    }

    /// What the gateway's loaded model can be asked for, written by the app after
    /// each health check. Stored in the App Group so the keyboard's own language
    /// menu reaches the same conclusion as the containing app rather than
    /// offering choices the app has already ruled out.
    static var modelLanguages: Set<String> {
        get { Set(defaults?.stringArray(forKey: modelLanguagesKey) ?? []) }
        set { defaults?.set(Array(newValue).sorted(), forKey: modelLanguagesKey) }
    }

    static var modelDetectsLanguage: Bool {
        get { defaults?.bool(forKey: modelDetectsLanguageKey) ?? false }
        set { defaults?.set(newValue, forKey: modelDetectsLanguageKey) }
    }

    /// The language claim that governs the picker.
    ///
    /// With on-device transcription on, the gateway's last engine report is
    /// irrelevant and often wrong in both directions: it can hide languages the
    /// local model supports, or offer ones it does not.
    private static var activeLocalModel: LocalModelDescriptor? {
        guard LocalTranscriptionPreferences.enabled else { return nil }
        return LocalModelCatalog.descriptor(for: LocalTranscriptionPreferences.modelIdentifier)
    }

    static var activeModelLanguages: Set<String> {
        activeLocalModel?.selectableLanguageCodes ?? modelLanguages
    }

    static var activeModelDetectsLanguage: Bool {
        activeLocalModel?.detectsLanguageAutomatically ?? modelDetectsLanguage
    }

    /// The language to actually dictate in, after discarding a stored choice the
    /// current model cannot honour.
    static var effectiveTranscriptionLanguage: TranscriptionLanguage {
        ModelLanguageSupport.resolve(
            transcriptionLanguage,
            modelLanguages: activeModelLanguages
        )
    }

    static var transcriptionLanguage: TranscriptionLanguage {
        get {
            guard let rawValue = defaults?.string(forKey: transcriptionLanguageKey),
                  let language = TranscriptionLanguage(rawValue: rawValue)
            else { return .automatic }
            return language
        }
        set {
            defaults?.set(newValue.rawValue, forKey: transcriptionLanguageKey)
        }
    }

    /// The language dictation should come out in, or `ModelTranslationSupport.off`
    /// to keep the language that was spoken.
    ///
    /// Deliberately a second setting rather than a meaning layered onto
    /// `transcriptionLanguage`. That one says what is being spoken, which is
    /// what a decoder needs; this one says what should come back, which only
    /// two models can honour at all.
    static var translateTo: TranscriptionLanguage {
        get {
            guard let rawValue = defaults?.string(forKey: translateToKey),
                  let language = TranscriptionLanguage(rawValue: rawValue)
            else { return ModelTranslationSupport.off }
            return language
        }
        set {
            defaults?.set(newValue.rawValue, forKey: translateToKey)
        }
    }

    /// Languages the active model can translate into; empty when it cannot.
    ///
    /// Empty for a gateway too, and not by omission: translation lives entirely
    /// in the on-device engines and the gateway protocol has no field for it.
    static var activeModelTranslationTargets: Set<String> {
        activeLocalModel?.translationTargets ?? []
    }

    /// Whether translating needs the spoken language set to something real.
    static var activeModelTranslationNeedsSource: Bool {
        activeLocalModel?.translationNeedsExplicitSource ?? false
    }

    /// The picker's own selection, corrected for a model that cannot honour it.
    static var effectiveTranslateTo: TranscriptionLanguage {
        ModelTranslationSupport.resolve(translateTo, targets: activeModelTranslationTargets)
    }

    /// What the engines take: a language code, or empty for no translation.
    static var translationTarget: String {
        ModelTranslationSupport.target(translateTo, targets: activeModelTranslationTargets)
    }

    /// Maintained by the containing app across foreground transitions. A custom
    /// keyboard only runs inside the frontmost app, so finding vocaphone in the
    /// foreground tells the keyboard that vocaphone is its own host.
    static var containingAppIsForeground: Bool {
        get { defaults?.bool(forKey: containingAppForegroundKey) ?? false }
        set { defaults?.set(newValue, forKey: containingAppForegroundKey) }
    }

    /// Set only after every required setup proof and the real keyboard practice
    /// insertion have succeeded. It is no longer a dismiss/seen flag.
    static var setupCompleted: Bool {
        get { defaults?.bool(forKey: setupCompletedKey) ?? false }
        set { defaults?.set(newValue, forKey: setupCompletedKey) }
    }

    /// One transcript has made it back from the gateway, which is the only
    /// proof that recording, upload, and transcription all work together.
    static var hasCompletedFirstDictation: Bool {
        get { defaults?.bool(forKey: firstDictationKey) ?? false }
        set { defaults?.set(newValue, forKey: firstDictationKey) }
    }

    /// A successful keyboard insertion into vocaphone's own practice field.
    /// This powers the stronger onboarding confirmation without changing the
    /// existing first-transcript activation milestone.
    static var hasCompletedKeyboardPractice: Bool {
        get { defaults?.bool(forKey: keyboardPracticeKey) ?? false }
        set { defaults?.set(newValue, forKey: keyboardPracticeKey) }
    }

    /// Existing users already proved a working transcript before the guided
    /// keyboard exercise existed. Preserve that experience on upgrade, but run
    /// the migration once so a later in-app diagnostic recording cannot satisfy
    /// the new keyboard-practice proof by accident.
    static func migrateKeyboardPracticeIfNeeded() {
        guard defaults?.bool(forKey: keyboardPracticeMigrationKey) != true else { return }
        defaults?.set(hasCompletedFirstDictation, forKey: keyboardPracticeKey)
        defaults?.set(true, forKey: keyboardPracticeMigrationKey)
    }

    static var microphonePreference: MicrophonePreference {
        get {
            guard let rawValue = defaults?.string(forKey: microphonePreferenceKey),
                  let preference = MicrophonePreference(rawValue: rawValue)
            else { return .automatic }
            return preference
        }
        set {
            defaults?.set(newValue.rawValue, forKey: microphonePreferenceKey)
        }
    }
}
