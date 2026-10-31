import Foundation

/// `assets/grammar/parity_fixtures.json` and the model's text files, read from
/// the repository. The same files back the Kotlin tests; both ports are checked
/// against `tools/grammar-eval/infer.py`'s output rather than against each other.
enum GrammarFixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("assets/grammar")

    struct PassFixture: Decodable {
        let words: [String]
        let ids: [Int64]
        let starts: [Int]
        let labels: [String]
        let chosen: [String]
    }

    struct Case: Decodable {
        let input: String
        let vocabulary: [String]
        let output: String
        let sentences: [[PassFixture]]
    }

    struct TokenizerWord: Decodable {
        let word: String
        let ids: [Int]
    }

    struct Document: Decodable {
        let model: Model
        let tokenizer: [TokenizerWord]
        let cases: [Case]

        struct Model: Decodable {
            let sha256: [String: String]
        }
    }

    static let document: Document = try! JSONDecoder().decode(
        Document.self, from: Data(contentsOf: root.appendingPathComponent("parity_fixtures.json"))
    )

    static let tokenizer: ByteLevelBpe = try! ByteLevelBpe.parse(
        Data(contentsOf: root.appendingPathComponent("model-text/tokenizer.json"))
    )

    static let labels: [String] = try! JSONDecoder().decode(
        [String].self, from: Data(contentsOf: root.appendingPathComponent("model-text/labels.json"))
    )

    static let pairs: [String] = try! JSONDecoder().decode(
        [String].self, from: Data(contentsOf: root.appendingPathComponent("model-text/plausible_pairs.json"))
    )

    static let index: [String: Int] = Dictionary(
        labels.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first }
    )

    static func tagger(
        keepBias: Float = GrammarTagger.keepBias,
        _ logits: @escaping GrammarTagger.Logits
    ) -> GrammarTagger {
        GrammarTagger(tokenizer: tokenizer, labels: labels, plausiblePairs: pairs, keepBias: keepBias, logits: logits)
    }

    /// One row per requested position, with all the weight (`score`) on `label`.
    static func row(_ label: String, score: Float = 10) -> [Float] {
        var row = [Float](repeating: 0, count: labels.count)
        row[index[label]!] = score
        return row
    }

    /// Plays back a case's labels: each pass's ids map to the label per word the model chose.
    static func replay(_ fixture: Case) -> GrammarTagger.Logits {
        var byIDs: [[Int64]: [String]] = [:]
        for passes in fixture.sentences {
            for pass in passes { byIDs[pass.ids] = pass.labels }
        }
        return { ids, rows in
            guard let chosen = byIDs[ids] else { throw FixtureMissing(ids: ids) }
            return rows.indices.map { row(chosen[$0]) }
        }
    }

    struct FixtureMissing: Error {
        let ids: [Int64]
    }
}
