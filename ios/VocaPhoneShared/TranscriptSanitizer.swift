import Foundation

/// Speech models annotate non-speech with bracketed markers — Whisper emits
/// `[BLANK_AUDIO]` for silence, others emit `[MUSIC]` or `(inaudible)` — and
/// fall into repetition loops when they run out of audio they can make sense
/// of. Both are diagnostics rather than something the user dictated, so neither
/// belongs in a text field. A transcript that is nothing but markers is treated
/// as nothing having been transcribed at all.
///
/// This mirrors the Android client's `TranscriptSanitizer`; the two are expected
/// to produce the same text for the same transcript.
enum TranscriptSanitizer {

    /// Deliberately a fixed list rather than "anything in brackets": a user can
    /// legitimately dictate "[1,200]" or "(see below)", and swallowing that
    /// would be worse than leaving a marker in.
    private static let markerWords: Set<String> = [
        "blank_audio", "blankaudio", "blank audio",
        "silence", "silent", "no speech", "no_speech", "nospeech",
        "music", "musique", "sound", "sounds",
        "noise", "background noise", "static",
        "inaudible", "unintelligible", "indistinct",
        "laughter", "laughs", "laughing", "applause", "coughing", "sighs",
        "pause", "beep", "clears throat"
    ]

    private static let bracketed = try? NSRegularExpression(
        pattern: "[\\[(<]\\s*([^\\[\\]()<>]{1,32}?)\\s*[\\])>]"
    )

    private static let runsOfSpaces = try? NSRegularExpression(pattern: "[ \\t]{2,}")

    /// Longest run treated as a loop. Beyond this it is prose, not a stutter.
    private static let maximumPhraseWords = 8

    static func clean(_ transcript: String?) -> String {
        guard let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "" }

        let withoutMarkers = stripMarkers(transcript)
        // Collapse the spacing the removal leaves behind, without touching the
        // line breaks the writing style may have produced.
        return withoutMarkers
            .components(separatedBy: "\n")
            .map { line in
                collapseRepetition(
                    replacing(runsOfSpaces, in: line, with: " ")
                        .trimmingCharacters(in: .whitespaces)
                )
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripMarkers(_ transcript: String) -> String {
        guard let bracketed else { return transcript }
        let text = transcript as NSString
        var result = ""
        var consumed = 0
        let matches = bracketed.matches(
            in: transcript, range: NSRange(location: 0, length: text.length)
        )
        for match in matches where match.numberOfRanges == 2 {
            let inner = text.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "*.!-_"))
            guard markerWords.contains(inner)
                || markerWords.contains(inner.replacingOccurrences(of: "_", with: " "))
            else { continue }
            result += text.substring(with: NSRange(
                location: consumed, length: match.range.location - consumed
            ))
            consumed = match.range.location + match.range.length
        }
        result += text.substring(from: consumed)
        return result
    }

    private static func replacing(
        _ expression: NSRegularExpression?, in line: String, with replacement: String
    ) -> String {
        guard let expression else { return line }
        return expression.stringByReplacingMatches(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length),
            withTemplate: replacement
        )
    }

    /// Collapses the repetition loop an attention model falls into when it runs
    /// out of audio it can make sense of — a phrase emitted over and over until
    /// the window ends. It is the single most recognizable way a transcript goes
    /// wrong, and unlike a bracketed marker there is no token to look for.
    ///
    /// The thresholds differ by length on purpose. A repeated phrase of two or
    /// more words is almost never something a person said three times running,
    /// so one copy is kept. A single word genuinely is — "no no no no" is a
    /// sentence — so it takes more repeats to look like a loop, and two copies
    /// survive to record that the emphasis was there.
    ///
    /// ``SpokenEmoji`` is the one exception to that first claim, and it has to
    /// be made here rather than in the stage that reads it: by the time the
    /// substitution runs this has already thrown the copies away.
    private static func collapseRepetition(_ line: String) -> String {
        guard !line.isEmpty else { return line }
        let words = line.components(separatedBy: " ").filter { !$0.isEmpty }
        guard words.count >= 4 else { return line }

        var result: [String] = []
        var index = 0
        while index < words.count {
            var phrase = 0
            var repeats = 0
            // Ascending, keeping the last match, so the longest repeating unit
            // wins: "thank you thank you thank you" is one phrase three times
            // over, not six unrelated words.
            let longest = min(maximumPhraseWords, (words.count - index) / 2)
            if longest >= 1 {
                for length in 1...longest {
                    let count = countRepeats(words, from: index, length: length)
                    if count >= (length == 1 ? 4 : 3) {
                        phrase = length
                        repeats = count
                    }
                }
            }
            // "crying emoji crying emoji crying emoji" is three emoji, not a
            // model stuck in a loop. Nobody says "emoji" three times running by
            // accident — it is the one word this app treats as a command, so a
            // unit ending on it was chosen deliberately and all the copies are
            // meant. Exempted whether or not the setting is on: the user still
            // said it three times, and a model looping on this exact phrase is
            // not a failure anyone has seen.
            if phrase >= 2, SpokenEmoji.triggerWords.contains(wordKey(words[index + phrase - 1])) {
                // Skip the whole run, not one word. Resuming inside it would
                // find the same repetition rotated by a word — "fire emoji"
                // four times over reads as "emoji fire" three times from index
                // one, and that unit does not end on the trigger.
                result.append(contentsOf: words[index..<(index + phrase * repeats)])
                index += phrase * repeats
                continue
            }
            guard phrase > 0 else {
                result.append(words[index])
                index += 1
                continue
            }
            // Taken from the source rather than the first copy repeated, so the
            // survivors keep the punctuation they arrived with.
            let kept = phrase == 1 ? 2 : 1
            result.append(contentsOf: words[index..<(index + phrase * kept)])
            index += phrase * repeats
        }
        return result.joined(separator: " ")
    }

    /// How many times the `length`-word unit at `start` repeats back to back.
    private static func countRepeats(_ words: [String], from start: Int, length: Int) -> Int {
        var repeats = 1
        var next = start + length
        while next + length <= words.count {
            for offset in 0..<length where wordKey(words[start + offset]) != wordKey(words[next + offset]) {
                return repeats
            }
            repeats += 1
            next += length
        }
        return repeats
    }

    /// Case and punctuation are exactly what differ between the copies in a loop
    /// — "Thank you." then "thank you," — so neither can take part in matching.
    private static func wordKey(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
