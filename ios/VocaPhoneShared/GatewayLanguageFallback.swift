import Foundation

/// What to do when the gateway refuses a recording as the wrong language.
///
/// The gateway answers `language_unsupported` for two quite different things.
/// One is real: the model was never trained on the language. The other is a
/// misread of a perfectly clear recording: a model that came back empty on it,
/// or one that wrote it in another alphabet (Hindi as Latin, say), which the
/// gateway's script check then rejects. Both arrive with the same code.
///
/// This app only pins a language the gateway's model lists (see
/// ``ModelLanguageSupport/resolve(_:modelLanguages:)``), so a refusal of a pinned
/// language is almost always the misread. Saying "your model does not support
/// this language" about a language it does support sent people to Settings for
/// nothing, and the same words dictated again then worked. So the recording is
/// sent once more with Automatic, and the answer is kept when it is written in
/// the requested language's alphabet or in Latin letters.
///
/// The alphabet check is what keeps Automatic safe. The gateway's own script
/// check exists because detecting models turn a short Hindi phrase into
/// Cyrillic or Chinese, and it never runs on Automatic, so it runs here
/// instead.
enum GatewayLanguageFallback {
    static let refusedCode = "language_unsupported"
    /// Sent as Automatic too, and still unreadable.
    static let misreadCode = "language_misread"

    static let misreadMessage =
        "Your gateway's model couldn't make out this recording. Tap Dictate and say it again."

    /// Whether a refusal is worth one resend with Automatic.
    static func shouldResend(code: String, language: String) -> Bool {
        code == refusedCode && language != TranscriptionLanguage.automatic.rawValue
    }

    /// Whether an Automatic transcript can stand in for `language`.
    ///
    /// Most letters have to be in that language's alphabet or in Latin. Latin is
    /// always allowed: someone with Hindi selected who said it in English, or in
    /// romanised Hindi, said those words. A language without a table entry is
    /// not checked, as on the gateway.
    static func accepts(_ transcript: String, for language: String) -> Bool {
        let code = language.lowercased().split(separator: "-").first.map(String.init) ?? language
        guard let expected = expectedScripts[code] else { return true }
        let allowed = expected.union(["LATIN"])
        let letters = transcript.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return true }
        let matching = letters.filter { allowed.contains(script(of: $0)) }.count
        return Double(matching) / Double(letters.count) >= minimumShare
    }

    /// A majority, unlike the gateway's 15 %: Latin is allowed as well, so a
    /// transcript in the right writing systems is nearly all of its letters.
    static let minimumShare = 0.5

    /// Unicode names start with their script: "DEVANAGARI LETTER MA".
    private static func script(of scalar: Unicode.Scalar) -> String {
        guard let name = scalar.properties.name else { return "" }
        return String(name.prefix { $0 != " " })
    }

    /// The non-Latin languages the picker offers, mirroring the gateway's
    /// `app/scripts.py`. Latin languages need no entry: Latin is always allowed.
    private static let expectedScripts: [String: Set<String>] = [
        "hi": ["DEVANAGARI"], "mr": ["DEVANAGARI"], "ne": ["DEVANAGARI"],
        "bn": ["BENGALI"], "as": ["BENGALI"],
        "gu": ["GUJARATI"], "kn": ["KANNADA"], "ml": ["MALAYALAM"],
        "ta": ["TAMIL"], "te": ["TELUGU"],
        "pa": ["GURMUKHI", "ARABIC"],
        "ar": ["ARABIC"], "fa": ["ARABIC"], "ur": ["ARABIC"],
        "ru": ["CYRILLIC"], "uk": ["CYRILLIC"], "bg": ["CYRILLIC"], "sr": ["CYRILLIC"],
        "el": ["GREEK"], "he": ["HEBREW"], "th": ["THAI"], "ko": ["HANGUL"],
        "ja": ["HIRAGANA", "KATAKANA", "CJK"], "zh": ["CJK"], "yue": ["CJK"],
    ]
}
