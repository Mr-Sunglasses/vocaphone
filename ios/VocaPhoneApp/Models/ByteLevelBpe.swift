import Foundation

/// The grammar tagger's tokenizer: GPT-2 style byte-level BPE, read from the
/// model's `tokenizer.json` (Hugging Face `tokenizers` format).
///
/// Only what that file uses is implemented: the ByteLevel pre-tokenizer with
/// its regex, no normalizer, no added prefix space, merges applied by rank.
/// `assets/grammar/parity_fixtures.json` pins the ids this must produce; the
/// Kotlin port (`ByteLevelBpe.kt`) is tested against the same file.
final class ByteLevelBpe: @unchecked Sendable {
    private struct Pair: Hashable {
        let first: String
        let second: String
    }

    private let vocab: [String: Int]
    private let ranks: [Pair: Int]
    private let unknownID: Int
    private let lock = NSLock()
    private var cache: [String: [Int]] = [:]

    init(vocab: [String: Int], merges: [(String, String)], unknownID: Int) {
        self.vocab = vocab
        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (rank, merge) in merges.enumerated() where ranks[Pair(first: merge.0, second: merge.1)] == nil {
            ranks[Pair(first: merge.0, second: merge.1)] = rank
        }
        self.ranks = ranks
        self.unknownID = unknownID
    }

    enum ParseError: Error { case malformed }

    static func parse(_ data: Data) throws -> ByteLevelBpe {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocabJSON = model["vocab"] as? [String: Any],
              let mergesJSON = model["merges"] as? [Any]
        else { throw ParseError.malformed }
        var vocab: [String: Int] = [:]
        vocab.reserveCapacity(vocabJSON.count)
        for (token, id) in vocabJSON {
            guard let id = (id as? NSNumber)?.intValue else { throw ParseError.malformed }
            vocab[token] = id
        }
        let merges: [(String, String)] = try mergesJSON.map { entry in
            if let pair = entry as? [String], pair.count == 2 { return (pair[0], pair[1]) }
            if let line = entry as? String, let space = line.firstIndex(of: " ") {
                return (String(line[..<space]), String(line[line.index(after: space)...]))
            }
            throw ParseError.malformed
        }
        let unknown = (model["unk_token"] as? String).flatMap { vocab[$0] } ?? 3
        return ByteLevelBpe(vocab: vocab, merges: merges, unknownID: unknown)
    }

    func encode(_ text: String) -> [Int] {
        let string = text as NSString
        var ids: [Int] = []
        for match in Self.preTokenizer.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let piece = string.substring(with: match.range)
            if let cached = lock.withLock({ cache[piece] }) {
                ids += cached
                continue
            }
            let encoded = bpe(piece)
            lock.withLock { if cache.count < 4096 { cache[piece] = encoded } }
            ids += encoded
        }
        return ids
    }

    private func bpe(_ piece: String) -> [Int] {
        var symbols = piece.utf8.map { String(Self.byteToCharacter[Int($0)]) }
        while symbols.count > 1 {
            var best = -1
            var bestRank = Int.max
            for i in 0..<(symbols.count - 1) {
                if let rank = ranks[Pair(first: symbols[i], second: symbols[i + 1])], rank < bestRank {
                    bestRank = rank
                    best = i
                }
            }
            if best < 0 { break }
            let first = symbols[best]
            let second = symbols[best + 1]
            // Merge every occurrence of the winning pair, left to right.
            var merged: [String] = []
            merged.reserveCapacity(symbols.count)
            var i = 0
            while i < symbols.count {
                if i < symbols.count - 1, symbols[i] == first, symbols[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }
        return symbols.map { vocab[$0] ?? unknownID }
    }

    /// GPT-2's pre-tokenizer pattern, which `tokenizers`' ByteLevel uses.
    private static let preTokenizer = try! NSRegularExpression(
        pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#
    )

    /// GPT-2's `bytes_to_unicode`: every byte gets a printable character.
    private static let byteToCharacter: [Character] = {
        let printable = Set(Array(33...126) + Array(161...172) + Array(174...255))
        var next = 256
        return (0..<256).map { byte in
            if printable.contains(byte) { return Character(UnicodeScalar(byte)!) }
            defer { next += 1 }
            return Character(UnicodeScalar(next)!)
        }
    }()
}
