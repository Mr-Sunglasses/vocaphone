import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Two more checkers for the Writing check screen, both Apple's and both on
/// this iPhone, which add to what the rules, the dictionary and the grammar
/// model found. Neither runs in the keyboard: the extension cannot reach them.
///
/// - **System grammar** (iOS 27): `UITextChecker`'s grammar check, run with
///   every check of the screen.
/// - **Deep check** (Apple Intelligence, iOS 26): the on-device language model
///   asked for a list of edits, when the user taps for it. Its edits are
///   generated, so each must name words that are in the text, change at most
///   a few of them, and is only ever offered, never applied.
///
/// Both come back as `WritingSuggestion`s; `merged` adds them to a report
/// where they do not clash with anything already found.
enum AppleProofreading {
    /// A suggestion that `text` should read `replacement` instead of its
    /// characters `start..<end`, as a card of `kind`, or nil when the span does
    /// not start and end on word boundaries or the change is not small.
    static func suggestion(
        in text: String, start: Int, end: Int, replacement: String, kind: WritingRules.Kind,
        reason: String, source: WritingSuggestion.Source
    ) -> WritingSuggestion? {
        let length = text.utf16Length
        guard start >= 0, start < end, end <= length else { return nil }
        let original = text.utf16Slice(start, end)
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != original, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Small: a typo, a word form, a missing or extra word. Not a rewrite.
        let before = WritingText.tokenize(original).filter(\.isWord).count
        let after = WritingText.tokenize(trimmed).filter(\.isWord).count
        guard before <= maximumWords, after <= maximumWords + 1, trimmed.utf16Length <= 80 else { return nil }
        let tokens = WritingText.tokenize(text)
        guard let from = tokens.firstIndex(where: { $0.start == start }),
              let last = tokens.lastIndex(where: { $0.end == end }), last >= from
        else { return nil }
        let sentences = WritingText.sentences(text, tokens)
        let floor = sentences.first(where: { $0.first <= from && from <= $0.last })?.first ?? 0
        let edit = WritingEdits.build(tokens, floor: floor, from: from, to: last + 1, inserted: trimmed)
        let values = ["original": original, "replacement": trimmed, "reason": reason]
        return WritingSuggestion(
            start: edit.start, end: edit.end, original: text.utf16Slice(edit.start, edit.end),
            replacement: edit.replacement, markStart: edit.markStart, markEnd: edit.markEnd,
            kind: kind.id, category: kind.category, title: kind.title,
            message: WritingEdits.format(kind.message, values), mechanical: false, source: source, rule: nil
        )
    }

    /// The most words a generated or system edit may replace.
    static let maximumWords = 4

    /// `extra` added to `report` where each clashes with nothing already
    /// there, nor with the user's own words; listed as `WritingCheck` lists.
    static func merged(_ report: WritingCheck.Report, _ extra: [WritingSuggestion], keep: Set<String>) -> WritingCheck.Report {
        var suggestions = report.suggestions
        for s in extra where s.isActionable {
            let words = Set(WritingText.tokenize(s.shownOriginal).filter(\.isWord).map(\.key))
            guard words.isDisjoint(with: keep) else { continue }
            if suggestions.contains(where: { $0.isActionable && $0.overlaps(s) }) { continue }
            suggestions.append(s)
        }
        let ordered = suggestions.enumerated().sorted { x, y in
            let a = (x.element.category.order, x.element.markStart, x.offset)
            let b = (y.element.category.order, y.element.markStart, y.offset)
            return a < b
        }.map(\.element)
        return WritingCheck.Report(
            text: report.text, suggestions: ordered, tones: report.tones, stats: report.stats,
            modelPending: report.modelPending
        )
    }

    /// Where `original` is in `text`, searching from UTF-16 offset `from`
    /// and then from the start; nil when it is not there at all.
    static func locate(_ original: String, in text: String, from: Int) -> (start: Int, end: Int)? {
        guard !original.isEmpty else { return nil }
        let ns = text as NSString
        var found = ns.range(of: original, options: [], range: NSRange(location: from, length: ns.length - from))
        if found.location == NSNotFound { found = ns.range(of: original) }
        guard found.location != NSNotFound else { return nil }
        return (found.location, found.location + found.length)
    }

    // MARK: - System grammar (iOS 27)

    #if compiler(>=6.4)
    /// One grammar issue the system found: where, the fix, and why.
    private struct SystemIssue: Sendable {
        let start: Int
        let length: Int
        let correction: String
        let reason: String
    }

    /// `UITextChecker`'s grammar results for `text`, as suggestions.
    @available(iOS 27, *)
    @MainActor
    static func systemGrammar(_ text: String, rules: WritingRules) async -> [WritingSuggestion] {
        let checker = UITextChecker()
        let range = NSRange(location: 0, length: text.utf16Length)
        let issues: [SystemIssue] = await withCheckedContinuation { done in
            checker.requestGrammarChecking(of: text, range: range, waitForAllResults: true) { results in
                // Read here, so only plain values leave the callback.
                var issues: [SystemIssue] = []
                for result in results where result.resultType == .grammar {
                    for detail in result.grammarDetails ?? [] {
                        guard let local = (detail["NSGrammarRange"] as? NSValue)?.rangeValue,
                              let correction = (detail["NSGrammarCorrections"] as? [String])?.first
                        else { continue }
                        issues.append(SystemIssue(
                            start: result.range.location + local.location, length: local.length,
                            correction: correction, reason: detail["NSGrammarUserDescription"] as? String ?? ""
                        ))
                    }
                }
                done.resume(returning: issues)
            }
        }
        let kind = rules.kind("system_grammar")
        return issues.compactMap { issue in
            let reason = issue.reason.isEmpty ? "The system's grammar check suggests “\(issue.correction)”." : issue.reason
            return suggestion(
                in: text, start: issue.start, end: issue.start + issue.length, replacement: issue.correction,
                kind: kind, reason: reason, source: .system
            )
        }
    }
    #endif

    // MARK: - Deep check (Apple Intelligence)

    /// Whether Deep check can run here: iOS 26 and an Apple Intelligence
    /// iPhone with the model ready.
    static var deepCheckAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), case .available = SystemLanguageModel.default.availability {
            return true
        }
        #endif
        return false
    }

    /// One edit, as the model gives it.
    struct Edit: Equatable, Sendable {
        let original: String
        let replacement: String
        let reason: String
    }

    /// The on-device model's edits for `text`, a paragraph at a time, as
    /// suggestions. Throws when the model refuses or fails.
    static func deepCheck(_ text: String, rules: WritingRules) async throws -> [WritingSuggestion] {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            var edits: [(Edit, Int)] = []
            for (chunk, offset) in chunks(text) {
                try Task.checkCancellation()
                for edit in try await DeepCheckModel.edits(chunk) { edits.append((edit, offset)) }
            }
            return suggestions(text, edits, rules: rules)
        }
        #endif
        return []
    }

    /// Generated edits placed in `text`: each where its words are, in order.
    static func suggestions(_ text: String, _ edits: [(Edit, Int)], rules: WritingRules) -> [WritingSuggestion] {
        let kind = rules.kind("deep_check")
        var out: [WritingSuggestion] = []
        var cursor = 0
        for (edit, offset) in edits {
            guard let at = locate(edit.original, in: text, from: max(cursor, offset)) else { continue }
            guard let s = suggestion(
                in: text, start: at.start, end: at.end, replacement: edit.replacement, kind: kind,
                reason: edit.reason, source: .generated
            ) else { continue }
            out.append(s)
            cursor = at.end
        }
        return out
    }

    /// `text` in pieces the model's context holds, each with its UTF-16 offset:
    /// paragraphs, and long ones by sentence.
    static func chunks(_ text: String, limit: Int = 1_200) -> [(String, Int)] {
        let tokens = WritingText.tokenize(text)
        var out: [(String, Int)] = []
        var start: Int?
        var end = 0
        for sentence in WritingText.sentences(text, tokens) {
            if let s = start, sentence.end - s > limit {
                out.append((text.utf16Slice(s, end), s))
                start = nil
            }
            if start == nil { start = sentence.start }
            end = sentence.end
        }
        if let s = start { out.append((text.utf16Slice(s, end), s)) }
        return out
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable
private struct DeepCheckEdits {
    @Guide(description: "Every spelling, grammar or punctuation mistake in the text, in the order they appear. Empty if there are none.")
    var edits: [DeepCheckEdit]
}

@available(iOS 26, *)
@Generable
private struct DeepCheckEdit {
    @Guide(description: "The wrong words exactly as they appear in the text, copied character for character: one to four words.")
    var original: String
    @Guide(description: "What those words should be, changing as little as possible.")
    var replacement: String
    @Guide(description: "One short sentence saying why, for the writer.")
    var reason: String
}

@available(iOS 26, *)
private enum DeepCheckModel {
    /// The same answer for the same text: always the likeliest word.
    static var options: GenerationOptions {
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy)
        #else
        GenerationOptions(sampling: .greedy)
        #endif
    }

    static let instructions = """
        You are a careful English proofreader. You list the mistakes in the text you are given: \
        spelling, grammar, word choice and punctuation. You never rewrite for style, never change \
        names, numbers, links or anything that is already correct, and you change as few words as possible.
        """

    static func edits(_ text: String) async throws -> [AppleProofreading.Edit] {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Proofread this text:\n\n\(text)",
            generating: DeepCheckEdits.self,
            options: options
        )
        return response.content.edits.map {
            AppleProofreading.Edit(original: $0.original, replacement: $0.replacement, reason: $0.reason)
        }
    }
}
#endif
