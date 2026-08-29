import Foundation

/// The marks a script closes a sentence with, and the rule for deciding which
/// script a transcript is written in.
///
/// Shared by ``TranscriptRepair``, which *inserts* marks, and
/// ``TranscriptStyler``, which formats around marks that are already there. Two
/// copies of this table would drift, and the visible failure is a Hindi
/// transcript that one stage ends with a danda and the other with a full stop.
struct SentencePunctuation: Sendable, Equatable {
    let terminator: String
    let separator: String
    let exclamation: String
    let question: String
    /// Every mark that can close a sentence: this script's, plus the ones a
    /// model borrows from other scripts often enough to matter.
    let terminators: String
    /// What sits between two sentences. Empty for the scripts that do not put a
    /// space after their punctuation.
    let join: String

    /// Whether sentences here are built the way English builds them — a full
    /// stop, a following space, a capital. ``TranscriptRepair``'s inference
    /// rules are written against English and are a no-op in any other Latin
    /// language, but a script that spaces differently would be damaged by them.
    var usesLatinLayout: Bool { join == " " && terminator == "." }

    /// Marks that never take a space before them and always take one after.
    static let universalTerminators = ".!?。！？।۔။។།؟"

    /// Marks that separate parts of a sentence rather than ending one.
    static let universalSeparators = ",;:،、၊"

    /// Every character the repair stage treats as punctuation, in any script.
    /// One list rather than a per-rule literal, because a rule that inserts a
    /// mark and a rule that spaces around one disagreeing about what a mark
    /// *is* is invisible until a transcript in that script comes out wrong.
    /// Contains no character-class metacharacter, so it can be interpolated
    /// into a `[...]` on both platforms and produce the same class.
    static let universalMarks = universalTerminators + universalSeparators + "…"

    static let latin = SentencePunctuation(
        terminator: ".", separator: ",", exclamation: "!", question: "?",
        terminators: ".!?", join: " "
    )
    static let cjk = SentencePunctuation(
        terminator: "。", separator: "、", exclamation: "！", question: "？",
        terminators: "。！？.!?", join: ""
    )
    static let arabic = SentencePunctuation(
        terminator: ".", separator: "،", exclamation: "!", question: "؟",
        terminators: ".!?؟", join: " "
    )
    static let urdu = SentencePunctuation(
        terminator: "۔", separator: "،", exclamation: "!", question: "؟",
        terminators: "۔.!?؟", join: " "
    )
    static let danda = SentencePunctuation(
        terminator: "।", separator: ",", exclamation: "!", question: "?",
        terminators: "।.!?", join: " "
    )
    /// Scripts written with a full stop rather than the danda their neighbours
    /// use. Still accepts a danda on input, because a multilingual model emits
    /// one for Tamil often enough.
    static let indicLatin = SentencePunctuation(
        terminator: ".", separator: ",", exclamation: "!", question: "?",
        terminators: "।.!?", join: " "
    )
    /// Thai and Lao close a sentence with a space, not a mark.
    static let unterminated = SentencePunctuation(
        terminator: "", separator: " ", exclamation: "!", question: "?",
        terminators: "!?", join: " "
    )
    static let burmese = SentencePunctuation(
        terminator: "။", separator: "၊", exclamation: "!", question: "?",
        terminators: "။.!?", join: " "
    )
    static let khmer = SentencePunctuation(
        terminator: "។", separator: ",", exclamation: "!", question: "?",
        terminators: "។.!?", join: " "
    )
    static let tibetan = SentencePunctuation(
        terminator: "།", separator: "།", exclamation: "!", question: "?",
        terminators: "།.!?", join: " "
    )

    /// The profile for `language`, falling back to what the text itself is
    /// written in when the engine reported nothing (Automatic).
    static func resolve(language: String, text: String) -> SentencePunctuation {
        let code = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
        let base: SentencePunctuation
        switch code {
        case "ja", "zh", "yue": base = cjk
        case "ar", "fa", "ps": base = arabic
        case "ur", "sd", "ks": base = urdu
        case "hi", "mr", "ne", "bn", "as", "pa": base = danda
        case "ta", "te", "kn", "ml", "gu", "si": base = indicLatin
        case "th", "lo": base = unterminated
        case "my": base = burmese
        case "km": base = khmer
        case "bo": base = tibetan
        default:
            if text.contains(where: { "。、！？".contains($0) }) { base = cjk }
            else if text.contains(where: { "،؟".contains($0) }) { base = arabic }
            else if text.contains("۔") { base = urdu }
            else if text.contains("।") || containsDandaScript(text) { base = danda }
            else { base = latin }
        }
        var seen = Set<Character>()
        let merged = String(
            (universalTerminators + base.terminators).filter { seen.insert($0).inserted }
        )
        return SentencePunctuation(
            terminator: base.terminator,
            separator: base.separator,
            exclamation: base.exclamation,
            question: base.question,
            terminators: merged,
            join: base.join
        )
    }

    /// Devanagari, Bengali/Assamese, and Gurmukhi conventionally use the danda.
    /// This is the fallback when Automatic was selected and the engine did not
    /// expose the language it detected.
    static func containsDandaScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0900...0x097F, 0x0980...0x09FF, 0x0A00...0x0A7F: true
            default: false
            }
        }
    }
}
