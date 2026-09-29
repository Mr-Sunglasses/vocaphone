import Foundation
@preconcurrency import WhisperKit

/// Everything a Whisper dictation is decoded with, captured once so a window
/// decoded during a pause and the same window at Finish are decoded alike —
/// and so a setting changed mid-recording is noticed rather than mixed in.
struct WhisperDictationSettings: Equatable, Sendable {
    /// nil for Automatic.
    let language: String?
    let translate: Bool
    let quality: TranscriptionQuality
    let vocabulary: String?

    @MainActor
    static func current(for descriptor: LocalModelDescriptor, language: String) -> WhisperDictationSettings {
        let resolved = descriptor.englishOnly ? "en" : language
        return WhisperDictationSettings(
            language: resolved == "auto" ? nil : resolved,
            // Whisper's translate task has exactly one trained target, English,
            // and `translationTarget` can only ever be "en" for a Whisper
            // model. Asking it for another target is not a smaller version of
            // the same feature; it is nothing at all.
            translate: !descriptor.resolvedTranslationTarget.isEmpty,
            quality: LocalTranscriptionPreferences.quality,
            vocabulary: LocalTranscriptionPreferences.customVocabulary
        )
    }

    /// Tokenized here rather than stored, because the tokens only mean anything
    /// against the tokenizer of the model that is loaded.
    @MainActor
    func decodingOptions(for whisperKit: WhisperKit) -> DecodingOptions {
        WhisperTranscription.decodingOptions(
            language: language,
            translate: translate,
            quality: quality,
            promptTokens: promptTokens(whisperKit.tokenizer)
        )
    }

    private func promptTokens(_ tokenizer: (any WhisperTokenizer)?) -> [Int]? {
        guard let tokenizer else { return nil }
        // WhisperKit drops special tokens from a prompt, so they are not counted.
        let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin
        func encode(_ text: String) -> [Int] {
            tokenizer.encode(text: text).filter { $0 < specialTokenBegin }
        }
        let prompt = CustomVocabulary.whisperPrompt(
            vocabulary,
            maximumTokens: CustomVocabulary.whisperKitPromptTokens
        ) { encode($0).count }
        return prompt.isEmpty ? nil : encode(prompt)
    }
}

/// One Whisper dictation in progress: its settings and the windows decoded
/// early. Owned by `LocalModelManager` between the start of the recording and
/// its transcription.
@MainActor
final class WhisperDictation {
    let modelID: String
    let settings: WhisperDictationSettings
    let cache = WhisperWindowCache()

    init(modelID: String, settings: WhisperDictationSettings) {
        self.modelID = modelID
        self.settings = settings
    }
}
