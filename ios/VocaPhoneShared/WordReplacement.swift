import Foundation

/// What an engine keeps writing for something the user says, and what to
/// write instead: "get hub" → "GitHub", "cube cuttle, cube control" →
/// "kubectl". Custom words fix close spellings of a word; a replacement is for
/// the hearing no spelling rule would connect to it. Mirrors
/// `WordReplacement.kt`, and the JSON is the same on both platforms.
struct WordReplacement: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// One or more heard forms, comma separated. Matching ignores case.
    var heard: String
    /// Exactly what to type instead.
    var written: String

    init(id: UUID = UUID(), heard: String, written: String) {
        self.id = id
        self.heard = heard
        self.written = written
    }

    /// Each non-empty heard form, its inner whitespace a single space.
    var heardForms: [String] {
        heard.split(separator: ",")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
    }

    var isValid: Bool {
        !heardForms.isEmpty && !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func encode(_ replacements: [WordReplacement]) -> Data? {
        try? JSONEncoder().encode(replacements)
    }

    static func decode(_ data: Data?) -> [WordReplacement] {
        guard let data, let decoded = try? JSONDecoder().decode([WordReplacement].self, from: data) else {
            return []
        }
        return decoded
    }
}

/// Applies `WordReplacement`s to a transcript, and the list operations both
/// Settings and anything that learns a replacement share.
enum WordReplacements {

    /// `list` with `heard` → `written` added. A row that already writes
    /// `written` takes the heard form beside its own, so one target stays one
    /// row; a heard form some row already has, compared ignoring case, is
    /// taken off that row first, so it never fires two ways. Several heard
    /// forms separated by commas ("get hub, git hub") are each added. Invalid
    /// input returns `list` unchanged.
    static func adding(heard: String, written: String, to list: [WordReplacement]) -> [WordReplacement] {
        let forms = heard.split(separator: ",")
        if forms.count > 1 {
            var result = list
            for form in forms {
                result = adding(heard: String(form), written: written, to: result)
            }
            return result
        }
        let form = heard.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let target = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !form.isEmpty, !form.contains(","), !target.isEmpty else { return list }
        let lowered = form.lowercased()
        var result: [WordReplacement] = []
        for var row in list {
            let kept = row.heardForms.filter { $0.lowercased() != lowered }
            if kept.count != row.heardForms.count {
                guard !kept.isEmpty else { continue }
                row.heard = kept.joined(separator: ", ")
            }
            result.append(row)
        }
        if let index = result.firstIndex(where: { $0.written == target }) {
            result[index].heard = (result[index].heardForms + [form]).joined(separator: ", ")
        } else {
            result.append(WordReplacement(heard: form, written: target))
        }
        return result
    }

    /// The written forms worth a speech model listening for, in list order.
    /// See `RecognitionHints.isHintableReplacement`.
    static func hintTargets(_ replacements: [WordReplacement]) -> [String] {
        replacements.filter(\.isValid).map(\.written)
    }

    /// `text` with every heard form replaced by its written form.
    ///
    /// Whole words only, ignoring case, longest heard form first so "open ai
    /// studio" wins over "open ai" where both match. One pass, left to right:
    /// a written form is never matched again. A match that overlaps
    /// `protectedRanges` — a snippet trigger, which expands later — is left as
    /// it is. Returns the new text and where the written forms sit in it, for
    /// the stages after this one to leave alone.
    static func apply(
        _ text: String,
        replacements: [WordReplacement],
        protectedRanges: [Range<String.Index>] = []
    ) -> (text: String, written: [Range<String.Index>]) {
        let forms = Self.forms(replacements)
        guard !text.isEmpty, !forms.isEmpty else { return (text, []) }
        let characters = Array(text)
        let lowered = characters.map { $0.lowercased() }
        let protected = protectedRanges.map { range in
            text.distance(from: text.startIndex, to: range.lowerBound)
                ..< text.distance(from: text.startIndex, to: range.upperBound)
        }

        var output = ""
        var written: [Range<Int>] = []
        var outputCount = 0
        var copiedUpTo = 0
        var index = 0
        while index < characters.count {
            guard let form = forms.first(where: {
                matches($0, at: index, characters: characters, lowered: lowered, protected: protected)
            }) else {
                index += 1
                continue
            }
            let unchanged = String(characters[copiedUpTo..<index])
            output += unchanged
            outputCount += unchanged.count
            output += form.written
            written.append(outputCount..<(outputCount + form.written.count))
            outputCount += form.written.count
            index += form.heard.count
            copiedUpTo = index
        }
        guard !written.isEmpty else { return (text, []) }
        output += String(characters[copiedUpTo...])
        let ranges = written.map { range in
            output.index(output.startIndex, offsetBy: range.lowerBound)
                ..< output.index(output.startIndex, offsetBy: range.upperBound)
        }
        return (output, ranges)
    }

    // MARK: - Matching

    private struct Form {
        /// Lowercased, one string per character.
        let heard: [String]
        let written: String
        let startsWithWord: Bool
        let endsWithWord: Bool
    }

    private static func forms(_ replacements: [WordReplacement]) -> [Form] {
        // Built with loops and typed steps: the chained version took over a
        // second to type-check, past what CI's Xcode 26 allows.
        var forms: [Form] = []
        for replacement in replacements where replacement.isValid {
            for heard in replacement.heardForms {
                let letters: [String] = heard.map { (character: Character) -> String in character.lowercased() }
                let starts: Bool = heard.first.map(isWordCharacter) ?? false
                let ends: Bool = heard.last.map(isWordCharacter) ?? false
                forms.append(Form(heard: letters, written: replacement.written, startsWithWord: starts, endsWithWord: ends))
            }
        }
        // Stable, so of two equally long forms the earlier row wins.
        var order: [Int] = Array(forms.indices)
        order.sort { (lhs: Int, rhs: Int) -> Bool in
            let lhsCount: Int = forms[lhs].heard.count
            let rhsCount: Int = forms[rhs].heard.count
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs < rhs
        }
        return order.map { (index: Int) -> Form in forms[index] }
    }

    /// Whether `form` is heard at `index`: the same characters ignoring case,
    /// starting and ending on a word boundary — or, for a form that starts or
    /// ends with punctuation, on whitespace — and touching no protected range.
    private static func matches(
        _ form: Form,
        at index: Int,
        characters: [Character],
        lowered: [String],
        protected: [Range<Int>]
    ) -> Bool {
        let end = index + form.heard.count
        guard end <= characters.count, lowered[index] == form.heard[0] else { return false }
        if index > 0 {
            let before = characters[index - 1]
            if form.startsWithWord ? isWordCharacter(before) : !before.isWhitespace { return false }
        }
        if end < characters.count {
            let after = characters[end]
            if form.endsWithWord ? isWordCharacter(after) : !after.isWhitespace { return false }
        }
        for offset in 1..<form.heard.count where lowered[index + offset] != form.heard[offset] {
            return false
        }
        return !protected.contains { $0.overlaps(index..<end) }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
