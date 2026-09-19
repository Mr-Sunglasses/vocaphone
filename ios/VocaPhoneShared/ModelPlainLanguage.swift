import Foundation

/// What a model is for, in words someone with no idea what a speech model is
/// can choose between.
///
/// The catalog's names are the upstream ones — "Parakeet TDT 0.6B", "Canary
/// 180M Flash" — and they are right to keep for anyone who looks the model up,
/// but on their own they say nothing about which one to download. The picker
/// leads with `title` and `summary` and keeps the upstream name as the small
/// print underneath.
///
/// The ratings are relative to the rest of this catalog, not measurements:
/// accuracy follows `LocalModelCatalog.accuracyRanking` and the published
/// numbers quoted beside each catalog entry, speed the arm64 timings recorded
/// there. Nothing here was benchmarked on a phone. Mirrors
/// `ModelPlainLanguage.kt`.
struct ModelPlainLanguage: Sendable, Equatable {
    /// A few words naming the job, such as "Most accurate English".
    let title: String
    /// One sentence on what the model is good at and what it costs.
    let summary: String
    /// 1 to 4, how often it gets the words right, relative to this catalog.
    let accuracy: Int
    /// 1 to 4, how quickly text appears after speaking, relative to this catalog.
    let speed: Int

    static let maximumRating = 4

    /// Every catalog id. `ModelPlainLanguageTests` fails when a model is added
    /// without an entry, so a new row cannot reach the picker unexplained.
    static let byID: [String: ModelPlainLanguage] = [
        "openai_whisper-base": .init(
            title: "Basic · most languages",
            summary: "Small and works with almost any language, but makes more mistakes.",
            accuracy: 1, speed: 3
        ),
        "openai_whisper-small_216MB": .init(
            title: "Good · most languages",
            summary: "Works with almost any language. Fewer mistakes than Basic, a little slower.",
            accuracy: 2, speed: 2
        ),
        "openai_whisper-large-v3-v20240930_626MB": .init(
            title: "Best · most languages",
            summary: "The most accurate choice for a language with no model of its own here. "
                + "Slower, and a large download.",
            accuracy: 4, speed: 1
        ),
        "omnilingual-300m-ctc": .init(
            title: "Hundreds of languages",
            summary: "Understands far more languages than anything else here, including rare ones. "
                + "Less accurate in common languages.",
            accuracy: 2, speed: 2
        ),
        "parakeet-tdt-ctc-110m-en": .init(
            title: "Small English",
            summary: "Accurate, fast English with punctuation, in a small download.",
            accuracy: 3, speed: 4
        ),
        "parakeet-tdt-0.6b-v2-en": .init(
            title: "Most accurate English",
            summary: "The most accurate English model here. A large download.",
            accuracy: 4, speed: 3
        ),
        "parakeet-tdt-0.6b-v3": .init(
            title: "European languages",
            summary: "Very accurate in 25 European languages, English included, "
                + "and tells them apart by itself.",
            accuracy: 4, speed: 3
        ),
        "sense-voice": .init(
            title: "Chinese, Japanese and Korean",
            summary: "Mandarin, Cantonese, Japanese, Korean and English in one fast model.",
            accuracy: 3, speed: 4
        ),
        "dolphin-small-ctc": .init(
            title: "Asian languages",
            summary: "Hindi, Bengali, Tamil, Thai, Indonesian and many more, "
                + "and tells them apart by itself.",
            accuracy: 2, speed: 3
        ),
        "canary-180m-flash": .init(
            title: "English, German, Spanish, French",
            summary: "Accurate in four languages, and can translate between them.",
            accuracy: 3, speed: 3
        ),
        "giga-am-v3-ru": .init(
            title: "Russian",
            summary: "Made for Russian, with punctuation. Far more accurate than the general models.",
            accuracy: 4, speed: 3
        ),
        "parakeet-tdt-ctc-ja": .init(
            title: "Most accurate Japanese",
            summary: "Made for Japanese. A large download.",
            accuracy: 4, speed: 3
        ),
        "paraformer-zh-small": .init(
            title: "Small Chinese",
            summary: "A small Mandarin model that is quick to download.",
            accuracy: 2, speed: 4
        ),
        "zipformer-ko": .init(
            title: "Small Korean",
            summary: "Made for Korean, in a small download.",
            accuracy: 3, speed: 4
        ),
        "zipformer-vi": .init(
            title: "Vietnamese",
            summary: "Made for Vietnamese: very accurate, in a small download.",
            accuracy: 4, speed: 4
        ),
    ]

    /// Falls back to the upstream facts, so a row can never render blank.
    static func of(_ model: LocalModelDescriptor) -> ModelPlainLanguage {
        byID[model.id] ?? ModelPlainLanguage(
            title: model.displayName,
            summary: model.languages,
            accuracy: 2,
            speed: 2
        )
    }

    /// "Accuracy 4 of 4, speed 3 of 4", for VoiceOver.
    var accessibilityRatings: String {
        "Accuracy \(accuracy) of \(Self.maximumRating), speed \(speed) of \(Self.maximumRating)"
    }
}

extension LocalModelDescriptor {
    var plain: ModelPlainLanguage { ModelPlainLanguage.of(self) }

    /// The upstream name with the maker, for the small print under `plain.title`.
    var technicalName: String { "\(displayName) · \(maker.displayName)" }
}
