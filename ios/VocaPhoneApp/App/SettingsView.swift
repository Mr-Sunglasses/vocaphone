import SwiftUI
import UIKit

/// The settings hub.
///
/// One screen used to hold routine preferences, gateway infrastructure, model
/// downloads, permissions and diagnostics in eleven sections, so finding the
/// writing style meant scrolling past a download manager. Five destinations,
/// grouped by what the person is trying to do rather than by which subsystem
/// owns the switch.
struct SettingsView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    // The hub's rows carry the values their destinations set, so they have to
    // be read through storage SwiftUI can see. Reading them from
    // `KeyboardPreferences` instead left every row showing the previous value
    // until the coordinator happened to publish something unrelated — which is
    // why the language row appeared to update "eventually" rather than never.
    @AppStorage(
        KeyboardPreferences.keyboardHeightKey,
        store: KeyboardPreferences.defaults
    ) private var keyboardHeightRawValue = KeyboardHeightPreference.standard.rawValue
    @AppStorage(
        KeyboardPreferences.transcriptionLanguageKey,
        store: KeyboardPreferences.defaults
    ) private var transcriptionLanguageRawValue = TranscriptionLanguage.automatic.rawValue
    @AppStorage(
        KeyboardPreferences.writingStyleKey,
        store: KeyboardPreferences.defaults
    ) private var writingStyleRawValue = WritingStyle.casual.rawValue
    @AppStorage(
        SnippetStore.key,
        store: SnippetStore.defaults
    ) private var snippetsData = Data()

    var body: some View {
        List {
            Section {
                destination(
                    "Keyboard",
                    detail: keyboardHeight.displayName,
                    symbol: "keyboard"
                ) { KeyboardSettingsView() }

                destination(
                    "Dictation",
                    detail: language.displayName + " · " + writingStyle.displayName,
                    symbol: "mic"
                ) { DictationSettingsView() }

                destination(
                    "Snippets",
                    detail: snippetCountDetail,
                    symbol: "text.badge.plus"
                ) { SnippetsSettingsView() }

                destination(
                    "Transcription",
                    detail: coordinator.setupStatus.source.title,
                    symbol: "waveform"
                ) { TranscriptionSettingsView() }

                destination(
                    "Privacy and permissions",
                    detail: nil,
                    symbol: "hand.raised"
                ) { PrivacySettingsView() }

                destination(
                    "Diagnostics",
                    detail: nil,
                    symbol: "stethoscope"
                ) { DiagnosticsSettingsView() }
            }

            Section {
                NavigationLink {
                    SetupView()
                } label: {
                    Label("Guided setup", systemImage: "checklist")
                }
            } footer: {
                Text(
                    "Guided setup re-checks the microphone, the keyboard and your "
                        + "transcription source, and can be reopened at any time."
                )
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var keyboardHeight: KeyboardHeightPreference {
        KeyboardHeightPreference(rawValue: keyboardHeightRawValue) ?? .standard
    }

    /// Resolved the same way the Dictation screen resolves it, so the hub never
    /// advertises a language the loaded model has already ruled out.
    private var language: TranscriptionLanguage {
        ModelLanguageSupport.resolve(
            TranscriptionLanguage(rawValue: transcriptionLanguageRawValue) ?? .automatic,
            modelLanguages: KeyboardPreferences.activeModelLanguages
        )
    }

    private var writingStyle: WritingStyle {
        WritingStyle(rawValue: writingStyleRawValue) ?? .casual
    }

    private var snippetCountDetail: String {
        let count = (try? JSONDecoder().decode([Snippet].self, from: snippetsData))?.count ?? 0
        return count == 0 ? "None" : "\(count) snippet\(count == 1 ? "" : "s")"
    }

    /// A row that carries its current value, so the hub answers most questions
    /// without being opened.
    private func destination(
        _ title: String,
        detail: String?,
        symbol: String,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        NavigationLink {
            content()
        } label: {
            LabeledContent {
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } label: {
                Label(title, systemImage: symbol)
            }
        }
    }
}

// MARK: - Keyboard

struct KeyboardSettingsView: View {
    @AppStorage(
        KeyboardPreferences.keyboardHeightKey,
        store: KeyboardPreferences.defaults
    ) private var keyboardHeightRawValue = KeyboardHeightPreference.standard.rawValue
    @AppStorage(
        KeyboardPreferences.typingSuggestionsKey,
        store: KeyboardPreferences.defaults
    ) private var suggestionsEnabled = true
    @AppStorage(
        KeyboardPreferences.autocorrectKey,
        store: KeyboardPreferences.defaults
    ) private var autocorrectEnabled = true
    @AppStorage(
        KeyboardPreferences.nextWordPredictionKey,
        store: KeyboardPreferences.defaults
    ) private var predictionEnabled = true
    @AppStorage(
        KeyboardPreferences.learnAsITypeKey,
        store: KeyboardPreferences.defaults
    ) private var learnAsITypeEnabled = true
    @AppStorage(
        KeyboardPreferences.smartPunctuationKey,
        store: KeyboardPreferences.defaults
    ) private var smartPunctuationEnabled = true
    @AppStorage(
        KeyboardPreferences.typingHapticsKey,
        store: KeyboardPreferences.defaults
    ) private var typingHapticsEnabled = false
    @AppStorage(
        KeyboardPreferences.emojiSuggestionsKey,
        store: KeyboardPreferences.defaults
    ) private var emojiSuggestionsEnabled = true
    @AppStorage(
        KeyboardPreferences.swipeTypingKey,
        store: KeyboardPreferences.defaults
    ) private var swipeTypingEnabled = false

    @State private var learnedStore = LearnedWordStore()
    @State private var learnedCount = 0
    @State private var isConfirmingLearnedReset = false

    private var selected: KeyboardHeightPreference {
        KeyboardHeightPreference(rawValue: keyboardHeightRawValue) ?? .standard
    }

    var body: some View {
        List {
            previewSection
            heightSection
            suggestionsSection
            learningSection
            typingDetailSection
            appearanceSection
        }
        .navigationTitle("Keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .task { learnedCount = learnedStore.snapshot().count }
        .confirmationDialog(
            "Forget \(learnedCount) learned word\(learnedCount == 1 ? "" : "s")?",
            isPresented: $isConfirmingLearnedReset,
            titleVisibility: .visible
        ) {
            Button("Forget them", role: .destructive) {
                learnedStore.removeAll()
                learnedCount = 0
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text(
                "The keyboard will start correcting these words again until it "
                    + "learns them a second time. Nothing else is affected."
            )
        }
    }

    /// The real keyboard, at the chosen height, redrawing as the switches move.
    private var previewSection: some View {
        Section {
            KeyboardPreview(preference: selected, showsSuggestions: suggestionsEnabled)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    private var heightSection: some View {
        Section {
            Picker("Height", selection: $keyboardHeightRawValue) {
                ForEach(KeyboardHeightPreference.allCases) { preference in
                    Text(preference.displayName).tag(preference.rawValue)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Height")
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(selected.detail)
                Text(
                    "Landscape keeps its own compact layout, because a landscape "
                        + "phone has no height to spare whichever size you pick."
                )
            }
        }
    }

    private var suggestionsSection: some View {
        Section {
            Toggle("Suggestions", isOn: $suggestionsEnabled)
            Toggle("Autocorrect", isOn: $autocorrectEnabled)
                .disabled(!suggestionsEnabled)
            Toggle("Predict the next word", isOn: $predictionEnabled)
                .disabled(!suggestionsEnabled)
        } header: {
            Text("Typing")
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                // The sentence users fear is "the keyboard now reads what you
                // type", so the answer sits next to the switch that turns it on.
                Text(
                    "Suggestions are worked out on this iPhone, by the same "
                        + "dictionary iOS uses everywhere else, plus your own words. "
                        + "Nothing you type is sent anywhere, logged, or included in "
                        + "a diagnostics export — not even to your gateway."
                )
                Text(
                    "Nothing is suggested in password, passcode or one-time-code "
                        + "fields, and nothing is learned from them."
                )
                if !suggestionsEnabled {
                    Text("Autocorrect and prediction need suggestions turned on.")
                }
            }
        }
    }

    private var learningSection: some View {
        Section {
            Toggle("Learn as I type", isOn: $learnAsITypeEnabled)
            Button(role: .destructive) {
                isConfirmingLearnedReset = true
            } label: {
                LabeledContent("Reset learned words", value: "\(learnedCount)")
            }
            .disabled(learnedCount == 0)
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(
                    "Words you type three times without undoing a correction, and "
                        + "words you tap in the suggestion row, stop being corrected "
                        + "away. They stay on this iPhone and are never added to the "
                        + "system-wide dictionary other apps use."
                )
                if !learnedStore.isPersistent {
                    Text(
                        "Full Access is off, so learned words last only until the "
                            + "keyboard closes."
                    )
                    .foregroundStyle(Color.vocaWarning)
                }
            }
        }
    }

    private var typingDetailSection: some View {
        Section {
            Toggle("Smart punctuation", isOn: $smartPunctuationEnabled)
            Toggle("Emoji suggestions", isOn: $emojiSuggestionsEnabled)
            Toggle("Typing haptics", isOn: $typingHapticsEnabled)
            Toggle("Swipe to type", isOn: $swipeTypingEnabled)
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(
                    "Smart punctuation curls quotes, turns two hyphens into an em "
                        + "dash and three dots into an ellipsis — except where the "
                        + "field asks it not to, such as a code or address field."
                )
                Text(
                    "Emoji suggestions offer one emoji beside the word candidates "
                        + "when a word has an obvious one — typing “lol” offers 😂. "
                        + "Tapping it replaces the word. It never takes a word "
                        + "suggestion's place, and words without an obvious emoji "
                        + "get none."
                )
                Text(
                    "Typing haptics are off by default. Keyboard clicks follow "
                        + "the iPhone's Keyboard Clicks setting. When enabled, "
                        + "custom haptics confirm committed typing and occasional "
                        + "keyboard actions."
                )
                // Said plainly rather than leaving people to wonder why their
                // keyboard is silent: the switch really does nothing without
                // Full Access, whatever it is set to.
                Text(
                    "Typing haptics also need Full Access. Without it iOS gives "
                        + "the keyboard no way to reach the Taptic Engine, and "
                        + "this switch does nothing. Keyboard clicks are "
                        + "unaffected."
                )
                Text(
                    "Swipe to type is new and off by default. Slide from letter to "
                        + "letter without lifting; alternatives appear in the "
                        + "suggestion row."
                )
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            NavigationLink {
                SetupView()
            } label: {
                Label("How to add the keyboard", systemImage: "questionmark.circle")
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text(
                "The keyboard follows the appearance of the app you are typing in, "
                    + "and this iPhone's light or dark setting. There is no separate "
                    + "keyboard theme to choose."
            )
        }
    }
}

// MARK: - Dictation

struct DictationSettingsView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @AppStorage(
        KeyboardPreferences.autoInsertKey,
        store: KeyboardPreferences.defaults
    ) private var autoInsertTranscripts = true
    @AppStorage(
        KeyboardPreferences.quickDictationKey,
        store: KeyboardPreferences.defaults
    ) private var quickDictationEnabled = true
    @AppStorage(
        KeyboardPreferences.quickDictationDurationKey,
        store: KeyboardPreferences.defaults
    ) private var quickDictationDurationRawValue = QuickDictationDuration.tenMinutes.rawValue
    @AppStorage(
        KeyboardPreferences.writingStyleKey,
        store: KeyboardPreferences.defaults
    ) private var writingStyleRawValue = WritingStyle.casual.rawValue
    @AppStorage(
        KeyboardPreferences.numbersAsDigitsKey,
        store: KeyboardPreferences.defaults
    ) private var numbersAsDigits = false
    @AppStorage(
        KeyboardPreferences.spokenEmojiKey,
        store: KeyboardPreferences.defaults
    ) private var spokenEmoji = true
    @AppStorage(
        KeyboardPreferences.repairSpeechKey,
        store: KeyboardPreferences.defaults
    ) private var repairSpeech = true
    @AppStorage(
        KeyboardPreferences.transcriptionLanguageKey,
        store: KeyboardPreferences.defaults
    ) private var transcriptionLanguageRawValue = TranscriptionLanguage.automatic.rawValue
    @AppStorage(
        KeyboardPreferences.translateToKey,
        store: KeyboardPreferences.defaults
    ) private var translateToRawValue = ModelTranslationSupport.off.rawValue
    @AppStorage(
        KeyboardPreferences.microphonePreferenceKey,
        store: KeyboardPreferences.defaults
    ) private var microphonePreferenceRawValue = MicrophonePreference.automatic.rawValue
    @AppStorage(
        KeyboardPreferences.recordingSoundsKey,
        store: KeyboardPreferences.defaults
    ) private var recordingSoundsEnabled = false
    @AppStorage(
        LocalTranscriptionPreferences.vocabularyKey,
        store: UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) private var savedCustomVocabulary = ""
    @State private var customVocabularyDraft = ""
    /// A `List` row re-runs `onAppear` when it scrolls back into view, and
    /// reloading the draft there would throw away a half-typed word.
    @State private var hasLoadedVocabularyDraft = false

    var body: some View {
        List {
            insertionSection
            quickDictationSection
            languageSection
            writingStyleSection
            cleanUpSection
            numbersSection
            spokenEmojiSection
            microphoneSection
            recordingFeedbackSection
            customWordsSection
        }
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var insertionSection: some View {
        Section {
            Toggle("Insert transcript automatically", isOn: $autoInsertTranscripts)
        } footer: {
            Text(
                autoInsertTranscripts
                    ? "The keyboard inserts text as soon as transcription finishes."
                    : "The keyboard shows the transcript and waits for you to tap Insert."
            )
        }
    }

    private var selectedQuickDictationDuration: QuickDictationDuration {
        QuickDictationDuration(rawValue: quickDictationDurationRawValue) ?? .tenMinutes
    }

    private var quickDictationSection: some View {
        Section {
            Toggle("Keep Quick Dictation ready", isOn: $quickDictationEnabled)
                .onChange(of: quickDictationEnabled) { _, enabled in
                    coordinator.setQuickDictationEnabled(enabled)
                }
            // Hidden rather than disabled when the feature is off: a greyed-out
            // duration for a window that will never open is noise.
            if quickDictationEnabled {
                Picker("Stay ready for", selection: $quickDictationDurationRawValue) {
                    ForEach(QuickDictationDuration.allCases) { duration in
                        Text(duration.displayName).tag(duration.rawValue)
                    }
                }
                .onChange(of: quickDictationDurationRawValue) { _, rawValue in
                    guard let duration = QuickDictationDuration(rawValue: rawValue) else { return }
                    coordinator.setQuickDictationDuration(duration)
                }
            }
        } footer: {
            Text(
                quickDictationEnabled
                    ? selectedQuickDictationDuration.settingsFooter
                    : "The keyboard's first Dictate tap opens vocaphone to record, then "
                        + "you swipe back. Turn this on to skip that trip."
            )
        }
    }

    /// One row that pushes to the full list, the way a `Picker` behaves in a
    /// form. Listing every language inline buried every setting below it, and
    /// a `Picker` cannot grey out the ones the loaded model cannot honour.
    private var languageSection: some View {
        Section {
            NavigationLink {
                TranscriptionLanguageList(selection: $transcriptionLanguageRawValue)
            } label: {
                LabeledContent("Language", value: selectedLanguage.displayName)
            }
            // Kept next to Language and never hidden. A row that disappears for
            // most models would leave the question unanswered, and "Not
            // supported by this model" is exactly the answer people arrive
            // looking for.
            NavigationLink {
                TranscriptionLanguageList(
                    selection: $translateToRawValue,
                    mode: .translation
                )
            } label: {
                LabeledContent(
                    "Translate to",
                    value: ModelTranslationSupport.summary(
                        storedTranslateTo,
                        targets: KeyboardPreferences.activeModelTranslationTargets,
                        onDevice: LocalTranscriptionPreferences.enabled,
                        needsExplicitSource: KeyboardPreferences.activeModelTranslationNeedsSource,
                        sourceIsAutomatic: KeyboardPreferences.effectiveTranscriptionLanguage
                            == .automatic
                    )
                )
            }
        } footer: {
            Text(selectedLanguage.detail)
        }
    }

    private var writingStyleSection: some View {
        Section {
            Picker("Writing style", selection: $writingStyleRawValue) {
                ForEach(WritingStyle.allCases) { style in
                    Label(style.displayName, systemImage: style.symbolName)
                        .tag(style.rawValue)
                }
            }
        } footer: {
            // The example earns its place in the footer by being the thing that
            // actually shows what the style does.
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(selectedWritingStyle.detail)
                Text("“\(selectedWritingStyle.example)”")
                Text(
                    "Styles only change formatting. Your words, times, links and "
                        + "contractions are never altered by a style; words change "
                        + "only through Clean up speech, Write numbers as digits "
                        + "and Spoken emoji, all below."
                )
            }
        }
    }

    /// The one switch in Dictation that changes words rather than formatting,
    /// which is why it says so in the footer instead of leaving it to be
    /// discovered.
    private var cleanUpSection: some View {
        Section {
            Toggle("Clean up speech", isOn: $repairSpeech)
        } header: {
            Text("Clean up")
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(
                    "Hesitation sounds and false starts are dropped, and missing "
                        + "sentence punctuation is filled in: “so um we should we "
                        + "should ship it friday” becomes “So we should ship it Friday.”"
                )
                Text(
                    "Only sounds with no meaning go — “um”, “uh”, “er”. Real words "
                        + "stay, including “like”, “you know” and “I mean”, and so do "
                        + "“mhm” and “uh-huh”, which are answers."
                )
                Text("Never applied to the Raw writing style.")
            }
        }
    }

    /// Number words to digits, for the people who dictate times, amounts and
    /// quantities all day and reformat every one of them by hand.
    private var numbersSection: some View {
        Section {
            Toggle("Write numbers as digits", isOn: $numbersAsDigits)
        } header: {
            Text("Numbers")
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(
                    "Numbers you say are written as digits: “six pm at the office” "
                        + "becomes “6 pm at the office”, and “twenty three” becomes “23”."
                )
                // Said plainly, because the exceptions are what stop this from
                // looking broken the first time it leaves a word alone.
                Text(
                    "A lone “one” stays a word unless a unit follows it, so “no one” "
                        + "and “one of them” are left alone. Ordinals such as “first” "
                        + "and spoken times such as “seven thirty” are never rewritten."
                )
                Text("English only. Transcripts in other languages are untouched.")
            }
        }
    }

    /// Saying "crying emoji" and getting 😭. The third switch that changes
    /// words rather than formatting, and the only one of the three that is on
    /// by default — the others apply to ordinary dictation, while this one
    /// cannot fire unless the user says "emoji" out loud.
    private var spokenEmojiSection: some View {
        Section {
            Toggle("Spoken emoji", isOn: $spokenEmoji)
        } header: {
            Text("Emoji")
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(
                    "Say the emoji and then the word “emoji”: “I’m so sad crying "
                        + "emoji” becomes “I’m so sad 😭”. The same names the "
                        + "keyboard suggests while you type work here."
                )
                // The exception is the point: without it the feature would eat
                // the word "emoji" out of ordinary sentences.
                Text(
                    "“Emoji” on its own is left alone, so “send me the emoji” is "
                        + "still typed as you said it."
                )
                Text(
                    "The emoji names are English. They still work in a transcript "
                        + "in any other language — say the English name and the rest "
                        + "of your sentence is untouched — but only by that name. "
                        + "Never applied to the Raw writing style."
                )
            }
        }
    }

    private var microphoneSection: some View {
        Section {
            Picker("Input selection", selection: $microphonePreferenceRawValue) {
                ForEach(MicrophonePreference.allCases) { preference in
                    Text(preference.displayName).tag(preference.rawValue)
                }
            }
            .disabled(!coordinator.canChangeMicrophone)
            .onChange(of: microphonePreferenceRawValue) { _, rawValue in
                guard let preference = MicrophonePreference(rawValue: rawValue) else { return }
                coordinator.setMicrophonePreference(preference)
            }

            LabeledContent("Input in use", value: coordinator.microphoneStatusLabel)
        } header: {
            Text("Microphone")
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(selectedMicrophonePreference.detail)
                Text(
                    "Bluetooth input and output routes are linked by iOS, so choosing a "
                        + "microphone can also change the playback route while recording."
                )
            }
        }
    }

    private var recordingFeedbackSection: some View {
        Section {
            Toggle("Play recording start and stop sounds", isOn: $recordingSoundsEnabled)
        } footer: {
            Text(
                "Short, quiet tones play outside the captured audio, so they are not "
                    + "included in the transcript. Haptic feedback remains available."
            )
        }
    }

    /// Saved on request rather than on every keystroke: the terms are parsed at
    /// inference time, and a half-typed name being persisted mid-word is a
    /// spelling nobody asked to be biased toward.
    private var customWordsSection: some View {
        Section {
            TextEditor(text: $customVocabularyDraft)
                .frame(minHeight: 88)
                .font(.body)
            Button("Save words") { savedCustomVocabulary = customVocabularyDraft }
                .disabled(customVocabularyDraft == savedCustomVocabulary)
        } header: {
            Text("Custom words")
        } footer: {
            let terms = CustomVocabulary.terms(customVocabularyDraft)
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(
                    "Names, places and jargon an on-device Whisper model is unlikely "
                        + "to know. One per line, or separated by commas."
                )
                Text(
                    terms.isEmpty
                        ? "No custom words. Transcription is unchanged."
                        : "\(terms.count) word\(terms.count == 1 ? "" : "s") will bias the "
                            + "decoder. This nudges spelling rather than guaranteeing it, and "
                            + "a very long list starts to crowd out the speech itself."
                )
                // Said plainly rather than letting the list quietly do nothing:
                // only Whisper's decoder has somewhere to put a vocabulary.
                if let unsupported = unsupportedVocabularyModel, !terms.isEmpty {
                    Text(
                        "\(unsupported) cannot use these words. Only Whisper models take a "
                            + "vocabulary; the list is kept for when you switch back to one."
                    )
                    .foregroundStyle(Color.vocaError)
                }
            }
        }
        .onAppear {
            guard !hasLoadedVocabularyDraft else { return }
            customVocabularyDraft = savedCustomVocabulary
            hasLoadedVocabularyDraft = true
        }
    }

    /// The selected on-device model when it cannot take a vocabulary, so the
    /// word list can say so instead of silently doing nothing.
    private var unsupportedVocabularyModel: String? {
        guard LocalTranscriptionPreferences.enabled,
              let descriptor = LocalModelCatalog.descriptor(
                  for: LocalTranscriptionPreferences.modelIdentifier
              ),
              !descriptor.supportsCustomVocabulary
        else { return nil }
        return descriptor.displayName
    }

    private var selectedWritingStyle: WritingStyle {
        WritingStyle(rawValue: writingStyleRawValue) ?? .casual
    }

    /// Read back out of the `@AppStorage` value rather than through
    /// `KeyboardPreferences`, exactly as `selectedWritingStyle` is.
    ///
    /// This is not a style preference. SwiftUI invalidates a view from the
    /// dynamic properties its body *reads*, and a static accessor is not one:
    /// `KeyboardPreferences.effectiveTranscriptionLanguage` reaches the same
    /// `UserDefaults` by a route SwiftUI cannot see, so a row that read it kept
    /// showing the previous language until something unrelated redrew the
    /// screen. Passing `$transcriptionLanguageRawValue` to the picker is not a
    /// read — it hands over the projected binding — so the property was written
    /// on every pick and never once observed here.
    private var selectedLanguage: TranscriptionLanguage {
        ModelLanguageSupport.resolve(
            TranscriptionLanguage(rawValue: transcriptionLanguageRawValue) ?? .automatic,
            modelLanguages: KeyboardPreferences.activeModelLanguages
        )
    }

    /// The stored target, before resolving: `ModelTranslationSupport.summary`
    /// does its own resolving, and needs to tell "Off" from a pick the current
    /// model cannot honour.
    private var storedTranslateTo: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: translateToRawValue) ?? ModelTranslationSupport.off
    }

    private var selectedMicrophonePreference: MicrophonePreference {
        MicrophonePreference(rawValue: microphonePreferenceRawValue) ?? .automatic
    }
}

// MARK: - Transcription

struct TranscriptionSettingsView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @AppStorage("gatewayURL") private var gatewayURL = ""
    @AppStorage(GatewayStatusPreferences.engineKey) private var gatewayEngine = ""
    @AppStorage(GatewayStatusPreferences.engineReadyKey)
    private var gatewayEngineReady = false
    @AppStorage(
        LocalTranscriptionPreferences.enabledKey,
        store: UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) private var localTranscriptionEnabled = false
    @AppStorage(
        LocalTranscriptionPreferences.qualityKey,
        store: UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) private var transcriptionQualityRawValue = TranscriptionQuality.default.rawValue
    @State private var engineReloadTask: Task<Void, Never>?
    @State private var engineReloadError: String?

    private var source: TranscriptionSourceStatus { coordinator.transcriptionSource }

    /// The engine the accuracy control is currently describing. Whisper is the
    /// safe default: it is the engine the setting has always applied to.
    private var selectedLocalEngine: LocalModelEngine {
        LocalTranscriptionPreferences.modelIdentifier
            .flatMap(LocalModelCatalog.descriptor(for:))?
            .engine ?? .whisperKit
    }

    /// Whether changing accuracy would build a different recognizer at all.
    private var selectedLocalEngineVariesWithQuality: Bool {
        guard let descriptor = LocalTranscriptionPreferences.modelIdentifier
            .flatMap(LocalModelCatalog.descriptor(for:))
        else { return true }
        guard descriptor.engine == .sherpaOnnx else { return true }
        return descriptor.sherpaFamily?.nativeConfigVariesWithQuality ?? true
    }

    var body: some View {
        List {
            routeSection
            if localTranscriptionEnabled {
                onDeviceSections
            } else {
                gatewaySection
            }
        }
        .navigationTitle("Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: localTranscriptionEnabled) { _, _ in
            coordinator.refreshSetupStatus()
        }
    }

    /// Switching routes never discards the other one's configuration: the
    /// gateway address and token stay in place, and a downloaded model stays
    /// downloaded, so the switch is reversible in one tap.
    private var routeSection: some View {
        Section {
            Picker(
                "Speech to text",
                selection: Binding(
                    get: { localTranscriptionEnabled },
                    set: { localTranscriptionEnabled = $0 }
                )
            ) {
                Text("On this iPhone").tag(true)
                Text("Your gateway").tag(false)
            }
            .pickerStyle(.segmented)

            VocaStatusLine(
                status: source.isReady ? .ready : .attention,
                title: source.title,
                detail: source.readinessDetail
            )
            .padding(.vertical, VocaMetrics.tight)
        } header: {
            Text("Source")
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(source.boundaryDetail)
                Text(source.alternativeSummary)
            }
        }
    }

    @ViewBuilder private var onDeviceSections: some View {
        Section {
            EmptyView()
        } header: {
            Text("On-device models")
        } footer: {
            Text(
                "Models run on this iPhone through WhisperKit/Core ML. Every file, "
                    + "including the tokenizer, is pinned and checked with SHA-256 before "
                    + "it can load, so transcription needs no network at all. The keyboard "
                    + "extension never loads the model itself."
            )
        }

        LocalModelPicker(
            manager: coordinator.localModels,
            onChange: {
                coordinator.refreshSetupStatus()
            },
            guidanceLanguage: KeyboardPreferences.transcriptionLanguage.rawValue
        )

        Section {
            Picker("Accuracy", selection: $transcriptionQualityRawValue) {
                ForEach(TranscriptionQuality.allCases) { quality in
                    Text(quality.displayName).tag(quality.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: transcriptionQualityRawValue) { _, _ in
                // Only where the setting reaches the native config. Rebuilding a
                // several-hundred-megabyte graph to produce a byte-identical one
                // is a long "Loading…" and a peak-memory spike for nothing.
                guard selectedLocalEngineVariesWithQuality else { return }
                reloadLocalEngine()
            }
            if let loading = coordinator.localModels.loadingMessage {
                Text(loading).foregroundStyle(.secondary)
            }
            // Reported rather than swallowed: rebuilding the engine is the one
            // thing this control does, and a silent failure here looks like the
            // setting having no effect.
            if let engineReloadError {
                Text(engineReloadError).foregroundStyle(Color.vocaError)
            }
        } header: {
            Text("Accuracy")
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(selectedTranscriptionQuality.detail(for: selectedLocalEngine))
                Text(
                    "This governs models running on this iPhone. Transcription on "
                        + "your gateway is unaffected."
                )
            }
        }
    }

    private var gatewaySection: some View {
        Section {
            NavigationLink {
                GatewaySetupView()
            } label: {
                LabeledContent {
                    Text(gatewayEngineReady ? "Ready" : "Not ready")
                } label: {
                    Text("Gateway")
                    Text(gatewayURL.isEmpty ? "Not configured" : gatewayURL)
                        .font(.footnote)
                }
            }

            if !gatewayEngine.isEmpty {
                LabeledContent("Speech-to-text model") {
                    Text(gatewayEngine)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }

            if let dashboardURL = GatewayEndpoint.validatedURL(from: gatewayURL) {
                Link(destination: dashboardURL) {
                    Label("Open web dashboard", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            Text("Gateway")
        } footer: {
            Text(
                "The gateway is a server you run yourself — on your LAN, over Tailscale, "
                    + "or on your own VPS. Choose its speech-to-text model in its own web "
                    + "dashboard. The pairing token is never included in that link."
            )
        }
    }

    private var selectedTranscriptionQuality: TranscriptionQuality {
        TranscriptionQuality.fromStored(transcriptionQualityRawValue)
    }

    /// A sherpa engine has its decoding method baked in, so changing the
    /// accuracy rebuilds it — but only one that is already loaded, and never a
    /// Whisper engine, which takes its decoding options per call. See
    /// `LocalModelManager.reloadForAccuracyChange`: this control must not be
    /// what pulls a speech-to-text model into memory.
    private func reloadLocalEngine() {
        engineReloadError = nil
        engineReloadTask?.cancel()
        engineReloadTask = Task { @MainActor in
            do {
                try await coordinator.localModels.reloadForAccuracyChange(
                    language: KeyboardPreferences.effectiveTranscriptionLanguage.rawValue
                )
            } catch is CancellationError {
                // Superseded by a later pick.
            } catch {
                engineReloadError = "The loaded model could not be rebuilt at this "
                    + "accuracy: \(error.localizedDescription). The next dictation "
                    + "will load it again."
            }
            engineReloadTask = nil
        }
    }
}

// MARK: - Privacy and permissions

struct PrivacySettingsView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @AppStorage(
        LocalTranscriptionPreferences.transcriptRetentionKey,
        store: UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) private var retentionRawValue = TranscriptRetention.default.rawValue
    @State private var isConfirmingDeleteAll = false

    private var retention: TranscriptRetention {
        TranscriptRetention.fromStored(retentionRawValue)
    }

    var body: some View {
        List {
            Section {
                VocaStatusLine(
                    status: microphoneStatus,
                    title: "Microphone",
                    detail: coordinator.setupStatus.detail(for: .microphone)
                )
                .padding(.vertical, VocaMetrics.tight)

                switch coordinator.microphoneAccess {
                case .undetermined:
                    Button("Allow microphone access") {
                        coordinator.requestMicrophonePermission()
                    }
                case .denied:
                    // iOS shows its permission alert only once, so re-prompting
                    // here would do nothing at all.
                    Button("Open iOS Settings", action: openSystemSettings)
                case .granted:
                    EmptyView()
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text(
                    "Recording always happens in this app. An iOS keyboard extension "
                        + "cannot use the microphone at all."
                )
            }

            Section {
                VocaStatusLine(
                    status: coordinator.setupStatus.keyboard.isReady ? .ready : .attention,
                    title: "Keyboard and Full Access",
                    detail: coordinator.setupStatus.detail(for: .keyboard)
                )
                .padding(.vertical, VocaMetrics.tight)
                Button("Open iOS Settings", action: openSystemSettings)
            } footer: {
                VStack(alignment: .leading, spacing: VocaMetrics.related) {
                    Text(AppConfiguration.fullAccessSettingsPath)
                    Text(
                        "Full Access lets the keyboard read the shared session state this "
                            + "app writes, and nothing else. It does not give the keyboard "
                            + "the microphone, and it does not send what you type anywhere."
                    )
                }
            }

            Section {
                LabeledContent(
                    "Audio",
                    value: coordinator.transcriptionSource.selected == .onDevice
                        ? "Never leaves this iPhone"
                        : "Sent to your gateway only"
                )
                Picker("Keep transcripts", selection: $retentionRawValue) {
                    ForEach(TranscriptRetention.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                Button(role: .destructive) {
                    isConfirmingDeleteAll = true
                } label: {
                    Label("Delete all transcripts", systemImage: "trash")
                }
            } header: {
                Text("What is kept")
            } footer: {
                VStack(alignment: .leading, spacing: VocaMetrics.related) {
                    Text(retention.detail)
                    Text(
                        "Audio is held on this iPhone until transcription succeeds, then "
                            + "deleted. Your gateway deletes successfully transcribed audio "
                            + "by default. Transcripts stay in the shared container on this "
                            + "phone so the keyboard can insert them. No third-party "
                            + "transcription or analytics service is used; usage reporting, "
                            + "if you turn it on, goes to a server VocaHQ self-hosts."
                    )
                }
            }

            // Next to "What is kept" rather than under Diagnostics: both answer
            // "what does this app keep or send", which is the question someone
            // is holding when they come looking for either.
            UsageReportingSettingsSection()

            Section {
                LabeledContent("Typing suggestions", value: "On this iPhone")
            } header: {
                Text("What the keyboard sees")
            } footer: {
                // The sentence users fear, answered where the claim is made.
                Text(
                    "Completions, corrections and next-word suggestions are worked out "
                        + "on this iPhone by the same dictionary iOS uses everywhere else, "
                        + "plus your own words. Nothing you type is sent anywhere — not "
                        + "even to your gateway — logged, or included in a diagnostics "
                        + "export. Nothing is suggested or learned in password, passcode "
                        + "or one-time-code fields."
                )
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete every transcript?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                Task { await coordinator.deleteAllTranscripts() }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text(
                "Every transcript is removed from this iPhone and cannot be "
                    + "recovered. Your settings and downloaded models are not affected."
            )
        }
    }

    private var microphoneStatus: VocaStatus {
        switch coordinator.microphoneAccess {
        case .granted: .ready
        case .denied: .failed
        case .undetermined: .attention
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Diagnostics

struct DiagnosticsSettingsView: View {
    @State private var diagnosticExportURL: URL?
    @State private var isSharingDiagnostics = false
    @State private var diagnosticsStatus: String?
    @State private var isConfirmingClear = false

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: Self.versionSummary)
            } header: {
                Text("Build")
            }

            Section {
                Button {
                    exportDiagnostics()
                } label: {
                    Label("Export diagnostics", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                VStack(alignment: .leading, spacing: VocaMetrics.related) {
                    Text(
                        "The bounded export contains up to seven days of build "
                            + "information, app/keyboard source, state transitions, and "
                            + "lifecycle errors only. It never contains transcripts, typed "
                            + "text, audio, addresses, or credentials."
                    )
                    if let diagnosticsStatus { Text(diagnosticsStatus) }
                }
            }

            // Destructive actions live in their own group at the bottom, away
            // from anything routine, and confirm before they run.
            Section {
                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Label("Clear diagnostics", systemImage: "trash")
                }
            } header: {
                Text("Reset")
            } footer: {
                Text("Clearing the diagnostic log cannot be undone. Transcripts are not affected.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear the diagnostic log?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear diagnostics", role: .destructive) {
                DiagnosticLog.clear()
                diagnosticsStatus = "Diagnostics cleared."
            }
            Button("Keep", role: .cancel) {}
        }
        .sheet(isPresented: $isSharingDiagnostics, onDismiss: removeDiagnosticExport) {
            if let diagnosticExportURL {
                DiagnosticShareSheet(activityItems: [diagnosticExportURL])
            }
        }
    }

    private static var versionSummary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func exportDiagnostics() {
        do {
            diagnosticExportURL = try DiagnosticLog.makeExportFile()
            diagnosticsStatus = nil
            isSharingDiagnostics = true
        } catch {
            DiagnosticLog.record(.operationFailed, metadata: .error(.diagnosticExportFailed))
            diagnosticsStatus = "The diagnostic export could not be prepared."
        }
    }

    private func removeDiagnosticExport() {
        if let diagnosticExportURL {
            try? FileManager.default.removeItem(at: diagnosticExportURL)
        }
        diagnosticExportURL = nil
    }
}

private struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

/// The full language list, reached from Dictation settings. Search matters at 54
/// entries, and the ones the loaded model cannot honour are grouped at the
/// bottom and greyed rather than hidden: a language that simply disappears reads
/// as unsupported by the app, when the fix is to change the model.
struct TranscriptionLanguageList: View {

    /// Which of the two language questions this list is asking.
    ///
    /// The rows, the search and the greying are identical; what differs is the
    /// title, what the first row means, which languages are selectable and what
    /// the footer says. Keeping them one view is what stops the two questions
    /// drifting apart in the ways that made them look like one setting in the
    /// first place.
    enum Mode {
        /// The language being spoken, which is what a decoder is told.
        case spoken
        /// The language the transcript should come back in.
        case translation
    }

    @Binding var selection: String
    var mode: Mode = .spoken
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var translating: Bool { mode == .translation }
    private var modelLanguages: Set<String> { KeyboardPreferences.activeModelLanguages }
    private var detectsLanguage: Bool { KeyboardPreferences.activeModelDetectsLanguage }
    private var translationTargets: Set<String> {
        KeyboardPreferences.activeModelTranslationTargets
    }

    // Searched against the label actually on the row: "Don't translate" is not
    // findable by typing "automatic", and should not be.
    private func matches(_ language: TranscriptionLanguage) -> Bool {
        ModelTranslationSupport.matchesQuery(query, language: language, translating: translating)
    }

    private func isSelectable(_ language: TranscriptionLanguage) -> Bool {
        translating
            ? ModelTranslationSupport.isSelectable(language, targets: translationTargets)
            : ModelLanguageSupport.isSelectable(language, modelLanguages: modelLanguages)
    }

    /// `.automatic` is the shared enum's way of storing "no choice", and in the
    /// translation list the absence of a choice is not language detection but
    /// no translation at all.
    private func label(_ language: TranscriptionLanguage) -> String {
        translating && language == ModelTranslationSupport.off
            ? ModelTranslationSupport.offLabel
            : language.displayName
    }

    private var footer: String? {
        translating
            ? ModelTranslationSupport.restriction(
                translationTargets,
                onDevice: LocalTranscriptionPreferences.enabled,
                needsExplicitSource: KeyboardPreferences.activeModelTranslationNeedsSource,
                sourceIsAutomatic: KeyboardPreferences.effectiveTranscriptionLanguage == .automatic
            )
            : ModelLanguageSupport.restriction(
                modelLanguages: modelLanguages,
                detectsLanguageAutomatically: detectsLanguage,
                canTranslate: ModelTranslationSupport.isSupported(translationTargets),
                onDevice: LocalTranscriptionPreferences.enabled
            )
    }

    private var checked: TranscriptionLanguage {
        let stored = TranscriptionLanguage(rawValue: selection) ?? .automatic
        return translating
            ? ModelTranslationSupport.resolve(stored, targets: translationTargets)
            : ModelLanguageSupport.resolve(stored, modelLanguages: modelLanguages)
    }

    private var available: [TranscriptionLanguage] {
        TranscriptionLanguage.allCases.filter { matches($0) && isSelectable($0) }
    }

    private var unavailable: [TranscriptionLanguage] {
        TranscriptionLanguage.allCases.filter { matches($0) && !isSelectable($0) }
    }

    var body: some View {
        List {
            if !available.isEmpty {
                Section {
                    ForEach(available) { language in
                        row(language, selectable: true)
                    }
                } footer: {
                    if let footer {
                        Text(footer)
                    }
                }
            }
            if !unavailable.isEmpty {
                Section("Needs a different model") {
                    ForEach(unavailable) { language in
                        row(language, selectable: false)
                    }
                }
            }
            if available.isEmpty && unavailable.isEmpty {
                Text("No language matches “\(query)”.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(translating ? "Translate to" : "Language")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search languages")
    }

    private func row(_ language: TranscriptionLanguage, selectable: Bool) -> some View {
        Button {
            selection = language.rawValue
            // Recents feed the keyboard's short spoken-language menu, which a
            // translation target has no place in.
            if !translating {
                KeyboardPreferences.noteTranscriptionLanguageUse(language)
            }
            dismiss()
        } label: {
            HStack {
                Text(label(language))
                    .foregroundStyle(selectable ? .primary : .secondary)
                Spacer()
                // Ticks what is in force, so the mark never sits on a row the
                // loaded model cannot honour.
                if language == checked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
        }
        .disabled(!selectable)
    }
}

// MARK: - Snippets

/// A trigger typed while dictating that expands into the longer text beside
/// it — a signature, an address, anything worth saying shorter.
struct SnippetsSettingsView: View {
    @State private var snippets: [Snippet] = SnippetStore.snippets
    @State private var isAddingSnippet = false
    @State private var editing: Snippet?

    var body: some View {
        List {
            Section {
                if snippets.isEmpty {
                    Text("No snippets yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snippets) { snippet in
                        SnippetRow(snippet: snippet) { editing = snippet }
                    }
                    .onDelete(perform: delete)
                }
            } footer: {
                Text(
                    "Say a trigger while dictating and vocaphone replaces it with the "
                        + "expansion. Matching ignores case; the expansion is inserted "
                        + "exactly as written, including its spacing."
                )
            }
        }
        .navigationTitle("Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingSnippet = true
                } label: {
                    Label("Add Snippet", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingSnippet) {
            SnippetEditorView(title: "Add Snippet", confirmation: "Add") { trigger, expansion in
                snippets.append(Snippet(trigger: trigger, expansion: expansion))
                persist()
            }
        }
        .sheet(item: $editing) { snippet in
            SnippetEditorView(
                title: "Edit Snippet",
                confirmation: "Save",
                snippet: snippet
            ) { trigger, expansion in
                guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
                snippets[index].trigger = trigger
                snippets[index].expansion = expansion
                persist()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        snippets.remove(atOffsets: offsets)
        persist()
    }

    /// Editing happens behind Cancel and Save, so every row here is already
    /// valid and the whole list is written as-is. Filtering at this point
    /// instead — dropping a row that momentarily failed validation — is what
    /// would make a half-finished edit delete an existing snippet outright.
    private func persist() {
        SnippetStore.snippets = snippets
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack {
                VStack(alignment: .leading, spacing: VocaMetrics.tight) {
                    Text(snippet.trigger)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(snippet.expansion)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityHint("Edits this snippet")
    }
}

/// Add and edit share one form. Nothing it collects reaches the store until
/// Save, so a trigger cleared halfway through retyping is never mistaken for
/// a snippet the user wanted emptied or removed.
private struct SnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var expansion: String
    let title: String
    let confirmation: String
    let onSave: (String, String) -> Void

    init(
        title: String,
        confirmation: String,
        snippet: Snippet? = nil,
        onSave: @escaping (String, String) -> Void
    ) {
        self.title = title
        self.confirmation = confirmation
        self.onSave = onSave
        _trigger = State(initialValue: snippet?.trigger ?? "")
        _expansion = State(initialValue: snippet?.expansion ?? "")
    }

    private var trimmedTrigger: String {
        trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trigger") {
                    TextField("e.g. sig", text: $trigger)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Expansion") {
                    TextField("Text to insert", text: $expansion, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmation) {
                        // The trigger is what matching keys off, so stray
                        // whitespace around it is noise; the expansion is kept
                        // as typed, since leading or trailing whitespace there
                        // can be exactly what the user wanted.
                        onSave(trimmedTrigger, expansion)
                        dismiss()
                    }
                    .disabled(
                        trimmedTrigger.isEmpty
                            || expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}

#if DEBUG

// MARK: - Previews

// All five destinations, plus the hub. The hub's rows used to read their value
// as a plain static property, which showed up here as a value that did not
// follow the store the preview supplies — and on device as a row that changed
// only when something unrelated redrew the screen. They read `@AppStorage` now,
// so the preview store is what they show.

#Preview("Settings — hub") {
    PreviewHost(coordinator: .previewIdle()) {
        NavigationStack { SettingsView() }
    }
}

#Preview("Settings — hub, on-device source") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: SetupStatus(
                source: PreviewFixtures.onDeviceReady,
                microphone: .granted,
                keyboard: .ready(lastSeenAt: Date()),
                hasDictatedOnce: true
            )
        )
    ) {
        NavigationStack { SettingsView() }
    }
}

#Preview("Settings — keyboard") {
    PreviewHost {
        NavigationStack { KeyboardSettingsView() }
    }
}

#Preview("Settings — snippets") {
    PreviewHost {
        NavigationStack { SnippetsSettingsView() }
    }
}

#Preview("Settings — dictation") {
    PreviewHost(coordinator: .previewIdle()) {
        NavigationStack { DictationSettingsView() }
    }
}

#Preview("Settings — transcription, gateway ready") {
    PreviewHost(coordinator: .previewIdle()) {
        NavigationStack { TranscriptionSettingsView() }
    }
}

#Preview("Settings — transcription, on-device") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: SetupStatus(
                source: PreviewFixtures.onDeviceReady,
                microphone: .granted,
                keyboard: .ready(lastSeenAt: Date()),
                hasDictatedOnce: true
            ),
            models: LocalModelManager(preview: [PreviewFixtures.firstModelID])
        )
    ) {
        NavigationStack { TranscriptionSettingsView() }
    }
}

#Preview("Settings — privacy, everything granted") {
    PreviewHost(coordinator: .previewIdle()) {
        NavigationStack { PrivacySettingsView() }
    }
}

/// The recovery wording for a permission iOS will not prompt for a second time.
#Preview("Settings — privacy, microphone denied") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupMicrophoneDenied
        )
    ) {
        NavigationStack { PrivacySettingsView() }
    }
}

#Preview("Settings — diagnostics") {
    PreviewHost {
        NavigationStack { DiagnosticsSettingsView() }
    }
}

#Preview("Settings — language list") {
    @Previewable @State var selection = TranscriptionLanguage.automatic.rawValue
    return PreviewHost {
        NavigationStack { TranscriptionLanguageList(selection: $selection) }
    }
}

#Preview("Settings — hub matrix", traits: .sizeThatFitsLayout) {
    PreviewMatrix(coordinator: .previewIdle()) {
        NavigationStack { SettingsView() }
    }
}

#Preview("Settings — transcription matrix", traits: .sizeThatFitsLayout) {
    PreviewMatrix(coordinator: .previewIdle()) {
        NavigationStack { TranscriptionSettingsView() }
    }
}
#endif
