import Foundation

/// Writing check's part-of-speech tagger: a greedy averaged perceptron over
/// Penn Treebank tags, trained by `tools/writing-tagger/train.py` and shipped
/// as `assets/keyboard/en-pos.bin`. A port of `tools/writing-tagger/postag.py`
/// and of `PosTagger.kt`; all three tag every sentence of
/// `assets/grammar/pos_fixtures.json` identically. 0.7 MB in memory, so it
/// runs in the keyboard extension (0.7 MB measured in the simulator).
final class PosTagger: Sendable {
    let tags: [String]
    private let tableKeys: [UInt64]
    private let tableTags: [UInt8]
    private let hashes: [UInt64]
    private let offsets: [UInt32]
    private let entryTags: [UInt8]
    private let entryWeights: [Int16]

    struct Failure: Error {}

    private static let start1 = "-START-"
    private static let start2 = "-START2-"
    private static let end1 = "-END-"
    private static let end2 = "-END2-"

    /// The tagger the app or keyboard ships, or nil if the file is missing or broken.
    static func bundled(_ bundle: Bundle = .main) -> PosTagger? {
        guard let url = bundle.url(forResource: "en-pos", withExtension: "bin"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return try? PosTagger(data: data)
    }

    /// Reads `en-pos.bin`; throws on a file that is not one.
    init(data: Data) throws {
        let parsed = try data.withUnsafeBytes { raw -> Parsed in
            var reader = Reader(raw: raw)
            guard try reader.u32() == 0x534F_5056, try reader.u32() == 1 else { throw Failure() }  // "VPOS", version 1
            let tagCount = Int(try reader.u16())
            var tags: [String] = []
            for _ in 0..<tagCount {
                let n = Int(try reader.u8())
                tags.append(try reader.string(n))
            }
            let tableCount = Int(try reader.u32())
            let tableKeys = try (0..<tableCount).map { _ in try reader.u64() }
            let tableTags = try (0..<tableCount).map { _ in try reader.u8() }
            let count = Int(try reader.u32())
            let hashes = try (0..<count).map { _ in try reader.u64() }
            let offsets = try (0...count).map { _ in try reader.u32() }
            let entries = Int(offsets[count])
            var entryTags = [UInt8](repeating: 0, count: entries)
            var entryWeights = [Int16](repeating: 0, count: entries)
            for e in 0..<entries {
                entryTags[e] = try reader.u8()
                entryWeights[e] = Int16(bitPattern: try reader.u16())
            }
            guard reader.atEnd else { throw Failure() }
            return Parsed(
                tags: tags, tableKeys: tableKeys, tableTags: tableTags, hashes: hashes, offsets: offsets,
                entryTags: entryTags, entryWeights: entryWeights
            )
        }
        tags = parsed.tags
        tableKeys = parsed.tableKeys
        tableTags = parsed.tableTags
        hashes = parsed.hashes
        offsets = parsed.offsets
        entryTags = parsed.entryTags
        entryWeights = parsed.entryWeights
    }

    private struct Parsed {
        let tags: [String]
        let tableKeys: [UInt64]
        let tableTags: [UInt8]
        let hashes: [UInt64]
        let offsets: [UInt32]
        let entryTags: [UInt8]
        let entryWeights: [Int16]
    }

    /// The tag of each of `words`, in order.
    func tag(_ words: [String]) -> [String] {
        var context = [Self.start1, Self.start2]
        context.reserveCapacity(words.count + 4)
        for w in words { context.append(Self.normalize(w)) }
        context.append(Self.end1)
        context.append(Self.end2)
        let shapes = words.map(Self.shape)
        var out: [String] = []
        out.reserveCapacity(words.count)
        var scores = [Int](repeating: 0, count: tags.count)
        var p1 = Self.start1
        var p2 = Self.start2
        for i in 0..<words.count {
            let word = context[i + 2]
            let best: Int
            if let fixed = Self.find(tableKeys, Self.fnv("w " + word)) {
                best = Int(tableTags[fixed])
            } else {
                for t in 0..<scores.count { scores[t] = 0 }
                for feature in Self.features(i, context, shapes, p1, p2) {
                    guard let f = Self.find(hashes, Self.fnv(feature)) else { continue }
                    for e in Int(offsets[f])..<Int(offsets[f + 1]) { scores[Int(entryTags[e])] += Int(entryWeights[e]) }
                }
                var b = 0
                for t in 1..<scores.count where scores[t] > scores[b] { b = t }
                best = b
            }
            let tag = tags[best]
            out.append(tag)
            p2 = p1
            p1 = tag
        }
        return out
    }

    /// 64-bit FNV-1a over the UTF-8 bytes of `text`.
    static func fnv(_ text: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    private static func find(_ sorted: [UInt64], _ key: UInt64) -> Int? {
        var lo = 0
        var hi = sorted.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < key { lo = mid + 1 } else if sorted[mid] > key { hi = mid - 1 } else { return mid }
        }
        return nil
    }

    /// What the features see of a word: lower-case ASCII, numbers and foreign words collapsed.
    static func normalize(_ word: String) -> String {
        let units = Array(word.utf16).map { $0 == 0x2019 ? 0x27 : $0 }
        if units.contains(where: { $0 > 127 }) { return "!FOREIGN" }
        let isDigit: (UInt16) -> Bool = { $0 >= 48 && $0 <= 57 }
        if !units.isEmpty, units.allSatisfy(isDigit) { return units.count == 4 ? "!YEAR" : "!DIGITS" }
        if let first = units.first, isDigit(first) { return "!DIGITS" }
        return String(decoding: units.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF16.self)
    }

    /// Capitalisation, which the lower-cased features lose: X (all caps), Xx, x, d, p, f.
    static func shape(_ word: String) -> String {
        let units = Array(word.utf16)
        if units.contains(where: { $0 > 127 }) { return "f" }
        guard let first = units.first else { return "p" }
        let upper: (UInt16) -> Bool = { $0 >= 65 && $0 <= 90 }
        let lower: (UInt16) -> Bool = { $0 >= 97 && $0 <= 122 }
        if first >= 48, first <= 57 { return "d" }
        if upper(first) {
            let letters = units.filter { upper($0) || lower($0) }
            return letters.count > 1 && letters.allSatisfy(upper) ? "X" : "Xx"
        }
        if lower(first) { return "x" }
        return "p"
    }

    private static func suffix(_ w: String) -> String {
        let units = Array(w.utf16)
        return units.count <= 3 ? w : String(decoding: units.suffix(3), as: UTF16.self)
    }

    private static func prefix(_ w: String) -> String { String(decoding: Array(w.utf16).prefix(1), as: UTF16.self) }

    static func features(_ i: Int, _ context: [String], _ shapes: [String], _ p1: String, _ p2: String) -> [String] {
        let w = context[i + 2]
        return [
            "b",
            "s " + suffix(w),
            "p " + prefix(w),
            "t1 " + p1,
            "t2 " + p2,
            "t12 " + p1 + " " + p2,
            "w " + w,
            "t1w " + p1 + " " + w,
            "w-1 " + context[i + 1],
            "s-1 " + suffix(context[i + 1]),
            "w-2 " + context[i],
            "w+1 " + context[i + 3],
            "s+1 " + suffix(context[i + 3]),
            "w+2 " + context[i + 4],
            "sh " + shapes[i],
        ]
    }

    /// Little-endian reads over the file's bytes.
    private struct Reader {
        let raw: UnsafeRawBufferPointer
        var position = 0

        init(raw: UnsafeRawBufferPointer) { self.raw = raw }

        var atEnd: Bool { position == raw.count }

        private mutating func advance(_ n: Int) throws -> Int {
            guard position + n <= raw.count else { throw Failure() }
            defer { position += n }
            return position
        }

        mutating func u8() throws -> UInt8 { raw[try advance(1)] }

        mutating func u16() throws -> UInt16 {
            UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: try advance(2), as: UInt16.self))
        }

        mutating func u32() throws -> UInt32 {
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: try advance(4), as: UInt32.self))
        }

        mutating func u64() throws -> UInt64 {
            UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: try advance(8), as: UInt64.self))
        }

        mutating func string(_ n: Int) throws -> String {
            let start = try advance(n)
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<(start + n)]), as: UTF8.self)
        }
    }
}
