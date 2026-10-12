import Foundation

/// Which characters Chinese dictation is written in.
///
/// Every on-device model writes Mandarin in Simplified characters, and so do
/// most gateway models, whatever the speaker reads. Someone in Taiwan or Hong
/// Kong otherwise gets text in a script they do not write. Converting the
/// finished transcript is the only fix that covers every model, and it costs
/// no download: the tables are OpenCC's and ship with the app.
///
/// A choice of writing system, not a correction, which is why it applies to
/// every writing style, `raw` included.
enum ChineseScript: String, Codable, CaseIterable, Identifiable, Sendable {
    case unchanged = "auto"
    case taiwan = "zh-TW"
    case hongKong = "zh-HK"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unchanged: "Unchanged"
        case .taiwan: "Traditional (Taiwan)"
        case .hongKong: "Traditional (Hong Kong)"
        }
    }

    var detail: String {
        switch self {
        case .unchanged: "Chinese comes out the way the model writes it, usually Simplified."
        case .taiwan: "软件 becomes 軟體: Taiwan characters and vocabulary."
        case .hongKong: "软件 becomes 軟件: Hong Kong characters and vocabulary."
        }
    }
}

/// Simplified → Traditional Chinese, using OpenCC's algorithm over OpenCC's
/// own tables.
///
/// `assets/keyboard/chinese/s2hant.tsv` is generated from OpenCC by
/// `tools/generate-chinese-script.py`, which also checks a Python copy of the
/// steps below against OpenCC itself. The Android port is `TraditionalChinese.kt`;
/// the three are kept step for step alike.
enum TraditionalChinese {
    /// The finished transcript in `script`, or unchanged when it is not
    /// Chinese.
    ///
    /// `language` is the language the text is written in. A language other
    /// than Mandarin or Cantonese is never converted: Japanese is written with
    /// the same characters, and 会社 is not a Chinese word to correct. Text
    /// holding any kana or Hangul is left alone for the same reason, whatever
    /// the language says — a model that detected Chinese in a mixed sentence
    /// has not made the Japanese in it Chinese.
    ///
    /// Web addresses are skipped: a path in Chinese characters names one
    /// page, and its Traditional spelling names another.
    static func apply(_ text: String, script: ChineseScript, language: String) -> String {
        guard script != .unchanged, appliesTo(text, language: language),
              let tables = tables
        else { return text }
        let string = text as NSString
        var output = ""
        var cursor = 0
        for match in webAddress?.matches(in: text, range: NSRange(location: 0, length: string.length)) ?? [] {
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            output += tables.convert(string.substring(with: before), region: script)
            output += string.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        return output + tables.convert(string.substring(from: cursor), region: script)
    }

    static func appliesTo(_ text: String, language: String) -> Bool {
        let base = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
        guard ["zh", "yue", "", "auto"].contains(base) else { return false }
        return containsHan(text) && !text.unicodeScalars.contains(where: isKanaOrHangul)
    }

    /// A scheme and everything up to the next space, as ``ProtectedSpans``
    /// reads an address. Bare domains need nothing: they are ASCII, which
    /// the tables leave alone.
    private static let webAddress = try? NSRegularExpression(pattern: "(?i:https?)://\\S+")

    /// Read once, on first use, and only by someone who has asked for
    /// Traditional: about a megabyte of tables nobody else should pay for.
    /// `warm()` moves that read off whichever actor finishes the first
    /// transcript.
    static let tables: Tables? = load()

    static func warm() {
        Task.detached(priority: .utility) { _ = tables }
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: true
            default: false
            }
        }
    }

    private static func isKanaOrHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
            true
        default:
            false
        }
    }

    struct Tables: Sendable {
        let normalize: Table
        let phrases: Table
        let characters: Table
        let taiwan: [Table]
        let hongKong: [Table]

        init?(parsing text: String) {
            var sections: [String: [String: String]] = [:]
            var current: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("#") { continue }
                if line.hasPrefix("@") {
                    current = String(line.dropFirst())
                    continue
                }
                guard let section = current,
                      let tab = line.firstIndex(of: "\t")
                else { continue }
                sections[section, default: [:]][String(line[..<tab])] =
                    String(line[line.index(after: tab)...])
            }
            func chain(_ prefix: String) -> [Table] {
                (1...).lazy.map { "\(prefix)\($0)" }
                    .prefix { sections[$0] != nil }
                    .map { Table(sections[$0]!) }
            }
            guard let phrases = sections["phrases"], let characters = sections["characters"]
            else { return nil }
            normalize = Table(sections["normalize"] ?? [:])
            self.phrases = Table(phrases)
            self.characters = Table(characters)
            taiwan = chain("tw")
            hongKong = chain("hk")
        }

        func convert(_ text: String, region: ChineseScript) -> String {
            let regional = region == .hongKong ? hongKong : taiwan
            let normalized = Array(Self.convert(Array(text.unicodeScalars), with: [normalize]).unicodeScalars)
            // Segment, then convert each segment on its own. A matched phrase
            // is a segment; the characters between matches are joined into
            // one, which is how a word no phrase holds — 软件 — still reaches
            // the regional table whole.
            var output = ""
            var run: Int?
            var index = 0
            func flushRun() {
                if let start = run {
                    output += convertSegment(normalized[start..<index], regional: regional)
                    run = nil
                }
            }
            while index < normalized.count {
                if let (length, _) = phrases.match(normalized, at: index) {
                    flushRun()
                    output += convertSegment(normalized[index..<index + length], regional: regional)
                    index += length
                } else {
                    if run == nil { run = index }
                    index += 1
                }
            }
            flushRun()
            return output
        }

        private func convertSegment(_ segment: ArraySlice<Unicode.Scalar>, regional: [Table]) -> String {
            let traditional = Self.convert(Array(segment), with: [phrases, characters])
            return Self.convert(Array(traditional.unicodeScalars), with: regional)
        }

        /// Longest match at each position. Several tables are OpenCC's
        /// short-circuit group: the first table with any match wins, even
        /// over a longer key in a later one.
        private static func convert(_ scalars: [Unicode.Scalar], with tables: [Table]) -> String {
            var output = String.UnicodeScalarView()
            var index = 0
            outer: while index < scalars.count {
                for table in tables {
                    if let (length, value) = table.match(scalars, at: index) {
                        output.append(contentsOf: value.unicodeScalars)
                        index += length
                        continue outer
                    }
                }
                output.append(scalars[index])
                index += 1
            }
            return String(output)
        }
    }

    /// Keyed by scalar arrays, not `String`: Swift compares strings by
    /// canonical equivalence, and a CJK compatibility ideograph is canonically
    /// equal to the character it normalizes to, which would make the two keys
    /// one.
    ///
    /// The longest key is fifteen characters, but most characters begin no key
    /// at all and the rest rarely begin a long one. Bounding the search by the
    /// longest key *starting with that character* turns most positions into a
    /// single dictionary miss rather than fifteen.
    struct Table: Sendable {
        private let entries: [[Unicode.Scalar]: String]
        private let longestFrom: [Unicode.Scalar: Int]

        init(_ entries: [String: String]) {
            var keyed: [[Unicode.Scalar]: String] = [:]
            var longestFrom: [Unicode.Scalar: Int] = [:]
            keyed.reserveCapacity(entries.count)
            for (key, value) in entries {
                let scalars = Array(key.unicodeScalars)
                guard let first = scalars.first else { continue }
                keyed[scalars] = value
                longestFrom[first] = max(longestFrom[first] ?? 0, scalars.count)
            }
            self.entries = keyed
            self.longestFrom = longestFrom
        }

        func match(_ scalars: [Unicode.Scalar], at start: Int) -> (Int, String)? {
            guard let longest = longestFrom[scalars[start]] else { return nil }
            var length = min(longest, scalars.count - start)
            while length > 0 {
                if let value = entries[Array(scalars[start..<start + length])] {
                    return (length, value)
                }
                length -= 1
            }
            return nil
        }
    }

    private static func load() -> Tables? {
        for url in candidateURLs() {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let tables = Tables(parsing: text) {
                return tables
            }
        }
        return nil
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        for bundle in [Bundle(for: TraditionalChineseAnchor.self), .main] {
            if let url = bundle.url(forResource: "chinese/s2hant", withExtension: "tsv") {
                urls.append(url)
            }
            if let url = bundle.url(forResource: "s2hant", withExtension: "tsv") {
                urls.append(url)
            }
        }
        // Unit tests compile this file into a bundle that does not embed the
        // shared assets; the repository copy is the file the app ships.
        urls.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("assets/keyboard/chinese/s2hant.tsv")
        )
        return urls
    }
}

/// `Bundle(for:)` needs a class. The enum above is not one.
private final class TraditionalChineseAnchor: NSObject {}
