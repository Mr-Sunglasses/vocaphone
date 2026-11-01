import Foundation
import Testing

/// `assets/grammar/pos_fixtures.json`, written by `tools/writing-tagger/fixtures.py`
/// from the reference tagger: the hash and every tag must match it exactly.
/// Mirrors `PosTaggerTest.kt`.
struct PosTaggerTests {
    nonisolated(unsafe) static let document: [String: Any] = try! JSONSerialization.jsonObject(
        with: Data(contentsOf: WritingCheckTests.root.appendingPathComponent("grammar/pos_fixtures.json"))
    ) as! [String: Any]

    @Test func hashesMatchTheReference() {
        for c in Self.document["fnv"] as! [[String: String]] {
            #expect(String(format: "%016llx", PosTagger.fnv(c["text"]!)) == c["hash"], "\(c["text"]!)")
        }
    }

    @Test func everySentenceIsTaggedAsTheReferenceTagsIt() {
        let tagger = WritingCheckTests.tagger
        let cases = Self.document["cases"] as! [[String: Any]]
        #expect(cases.count >= 20)
        for c in cases {
            let text = c["text"] as! String
            let words = c["words"] as! [String]
            #expect(WritingText.tokenize(text).map(\.text) == words, "\(text)")
            #expect(tagger.tag(words) == c["tags"] as! [String], "\(text)")
        }
    }
}
