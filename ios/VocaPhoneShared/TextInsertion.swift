import Foundation

enum TextInsertion {
    static func preparedTranscript(
        _ transcript: String,
        before: String?,
        after: String?
    ) -> String {
        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        if let last = before?.last,
           !last.isWhitespace,
           !result.first!.isPunctuation {
            result = " " + result
        }

        if let first = after?.first,
           !first.isWhitespace,
           !first.isPunctuation,
           !result.last!.isWhitespace {
            result += " "
        }
        return result
    }
}
