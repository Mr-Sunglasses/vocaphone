import SwiftUI

// One sentence under a control, the rest one tap away.
//
// Settings footers had grown into the only place every rule, exception and
// edge case lived: Clean up speech alone carried three paragraphs, and the
// Dictation page was ten sections of them. People read the first line of a
// footer, if that. So each control now says what it does in one line, and the
// full explanation — nothing deleted, only moved — sits behind an ⓘ in its
// section header.

/// A control's title with the one line that says what it does.
struct SettingLabel: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The full explanation behind a section's ⓘ.
struct LearnMoreTopic: Identifiable {
    struct Part {
        let heading: String
        let paragraphs: [String]
    }

    let title: String
    let parts: [Part]

    var id: String { title }
}

/// A section header with an ⓘ that opens its topic.
struct LearnMoreHeader: View {
    let title: String
    let topic: LearnMoreTopic
    @Binding var presented: LearnMoreTopic?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                presented = topic
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
            }
            .buttonStyle(.borderless)
            .textCase(nil)
            .accessibilityLabel("About \(title.lowercased())")
        }
    }
}

struct LearnMoreSheet: View {
    let topic: LearnMoreTopic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(topic.parts, id: \.heading) { part in
                    Section(part.heading) {
                        ForEach(part.paragraphs, id: \.self) { paragraph in
                            Text(paragraph)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle(topic.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Where the technical explanation lives: how models are run and checked,
/// what Full Access does, what is kept, what the keyboard sees. Reached from
/// Privacy and from Voice model, so the screens themselves can say it in one
/// plain sentence.
struct HowItWorksView: View {
    var body: some View {
        List {
            ForEach(SettingsHelp.howItWorks.parts, id: \.heading) { part in
                Section(part.heading) {
                    ForEach(part.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(SettingsHelp.howItWorks.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The longer explanations, word for word where they came from a footer.
enum SettingsHelp {
    static let output = LearnMoreTopic(
        title: "How your words are written",
        parts: [
            .init(heading: "Writing style", paragraphs: [
                "Styles only change formatting. Your words, times, links and "
                    + "contractions are never altered by a style; words change only "
                    + "through Clean up speech, Write numbers as digits and Spoken "
                    + "emoji.",
            ] + WritingStyle.allCases.map { "\($0.displayName): \($0.detail)" }),
            .init(heading: "Clean up speech", paragraphs: [
                "Hesitation sounds and false starts are dropped, and missing "
                    + "sentence punctuation is filled in: “so um we should we should "
                    + "ship it friday” becomes “So we should ship it Friday.”",
                "Only sounds with no meaning go — “um”, “uh”, “er”. Real words "
                    + "stay, including “like”, “you know” and “I mean”, and so do "
                    + "“mhm” and “uh-huh”, which are answers.",
                "Never applied to the Raw writing style.",
            ]),
            .init(heading: "Write numbers as digits", paragraphs: [
                "Numbers you say are written as digits: “six pm at the office” "
                    + "becomes “6 pm at the office”, and “twenty three” becomes “23”.",
                "A lone “one” stays a word unless a unit follows it, so “no one” "
                    + "and “one of them” are left alone. Ordinals such as “first” and "
                    + "spoken times such as “seven thirty” are never rewritten.",
                "English only. Transcripts in other languages are untouched.",
            ]),
            .init(heading: "Spoken emoji", paragraphs: [
                "Say the emoji and then the word “emoji”: “crying emoji” becomes "
                    + "😭. The whole name has to match — a partial suffix is left "
                    + "alone. The same names the keyboard suggests while you type "
                    + "work here.",
                "“Emoji” on its own is left alone, so “send me the emoji” is still "
                    + "typed as you said it.",
                "The emoji names are English. They still work in a transcript in "
                    + "any other language — say the English name and the rest of "
                    + "your sentence is untouched — but only by that name. Never "
                    + "applied to the Raw writing style.",
            ]),
        ]
    )

    static func recording(quickDictation: String) -> LearnMoreTopic {
        LearnMoreTopic(
            title: "About recording",
            parts: [
                .init(heading: "Quick Dictation", paragraphs: [
                    quickDictation,
                    "With it off, the keyboard's first Dictate tap opens vocaphone to "
                        + "record, then you swipe back.",
                ]),
                .init(heading: "Microphone", paragraphs: [
                    "Bluetooth input and output routes are linked by iOS, so "
                        + "choosing a microphone can also change the playback route "
                        + "while recording.",
                ] + MicrophonePreference.allCases.map { "\($0.displayName): \($0.detail)" }),
                .init(heading: "Sounds and pauses", paragraphs: [
                    "Short, quiet tones play outside the captured audio, so they are "
                        + "not included in the transcript. Haptic feedback remains "
                        + "available.",
                    "Stop after a pause finishes a dictation by itself after three "
                        + "seconds of quiet following at least a second of speech. "
                        + "Leave it off if you pause to think while you talk.",
                ]),
            ]
        )
    }

    static let customWords = LearnMoreTopic(
        title: "Custom words",
        parts: [
            .init(heading: "What they do", paragraphs: [
                "Names, places and jargon a speech model is unlikely to know. One "
                    + "per line, or separated by commas.",
                "Each word is spelled your way when the transcript comes close — "
                    + "\"whisper kit\" becomes \"WhisperKit\". Whisper models are also "
                    + "nudged toward them while decoding; a very long list starts to "
                    + "crowd out the speech itself.",
                "Other models cannot be nudged while they decode, so only close "
                    + "matches are corrected. A word such a model hears as something "
                    + "else entirely stays as it heard it.",
            ]),
        ]
    )

    static let typing = LearnMoreTopic(
        title: "About typing",
        parts: [
            .init(heading: "Suggestions", paragraphs: [
                "Suggestions are worked out on this iPhone, by the same dictionary "
                    + "iOS uses everywhere else, plus your own words. Nothing you type "
                    + "is sent anywhere, logged, or included in a diagnostics export — "
                    + "not even to your gateway.",
                "Nothing is suggested in password, passcode or one-time-code fields, "
                    + "and nothing is learned from them.",
            ]),
            .init(heading: "Learn as I type", paragraphs: [
                "Words you type three times without undoing a correction, and words "
                    + "you tap in the suggestion row, stop being corrected away. They "
                    + "stay on this iPhone and are never added to the system-wide "
                    + "dictionary other apps use.",
                "Without Full Access, learned words last only until the keyboard "
                    + "closes.",
            ]),
            .init(heading: "Height", paragraphs: [
                "Landscape keeps its own compact layout, because a landscape phone "
                    + "has no height to spare whichever size you pick.",
            ]),
            .init(heading: "More typing options", paragraphs: [
                "Smart punctuation curls quotes, turns two hyphens into an em dash "
                    + "and three dots into an ellipsis — except where the field asks "
                    + "it not to, such as a code or address field.",
                "Emoji suggestions offer one emoji beside the word candidates when a "
                    + "word has an obvious one — “happy” offers 😊 and “sad” offers "
                    + "😢. Tap the emoji before adding a space to replace the word. "
                    + "Words without an obvious emoji get none.",
                "Typing haptics are off by default. Keyboard clicks follow the "
                    + "iPhone's Keyboard Clicks setting. When enabled, custom haptics "
                    + "confirm committed typing and occasional keyboard actions.",
                "Typing haptics also need Full Access. Without it iOS gives the "
                    + "keyboard no way to reach the Taptic Engine, and the switch does "
                    + "nothing. Keyboard clicks are unaffected.",
                "Swipe to type is new and off by default. Slide from letter to letter "
                    + "without lifting; alternatives appear in the suggestion row.",
                "Space bar cursor: hold the space bar, then slide to move the cursor. "
                    + "With two keyboard languages, a swipe across it switches "
                    + "language instead.",
            ]),
        ]
    )

    static let howItWorks = LearnMoreTopic(
        title: "How it works",
        parts: [
            .init(heading: "Speech to text", paragraphs: [
                "On this iPhone, models run through WhisperKit (Core ML) and "
                    + "sherpa-onnx. Every file, including the tokenizer, is pinned "
                    + "and checked with SHA-256 before it can load, so transcription "
                    + "needs no network at all. The keyboard extension never loads "
                    + "the model itself.",
                "The gateway is a server you run yourself — on your LAN, over "
                    + "Tailscale, or on your own VPS. You choose its speech-to-text "
                    + "model in its own web dashboard. The pairing token is never "
                    + "included in the dashboard link.",
            ]),
            .init(heading: "The keyboard and Full Access", paragraphs: [
                "Recording always happens in the vocaphone app. An iOS keyboard "
                    + "extension cannot use the microphone at all.",
                "Full Access lets the keyboard read the shared session state this "
                    + "app writes, and nothing else. It does not give the keyboard "
                    + "the microphone, and it does not send what you type anywhere.",
            ]),
            .init(heading: "What is kept", paragraphs: [
                "Audio is held on this iPhone until transcription succeeds, then "
                    + "deleted. Your gateway deletes successfully transcribed audio "
                    + "by default. Transcripts stay in the shared container on this "
                    + "phone so the keyboard can insert them.",
                "No third-party transcription or analytics service is used; usage "
                    + "reporting, if you turn it on, goes to a server VocaHQ "
                    + "self-hosts.",
            ]),
            .init(heading: "What the keyboard sees", paragraphs: [
                "Completions, corrections and next-word suggestions are worked out "
                    + "on this iPhone by the same dictionary iOS uses everywhere else, "
                    + "plus your own words. Nothing you type is sent anywhere — not "
                    + "even to your gateway — logged, or included in a diagnostics "
                    + "export. Nothing is suggested or learned in password, passcode "
                    + "or one-time-code fields.",
            ]),
        ]
    )
}
