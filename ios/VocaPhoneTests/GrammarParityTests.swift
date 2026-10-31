import Foundation
import Testing

/// Mirrors android/.../grammar/GrammarParityTest.kt.
struct GrammarParityTests {
    private static let pins: LocalModelIntegrity.PinnedModelManifest = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VocaPhoneApp/Models/grammar_model_pins.json")
        let manifest = try! JSONDecoder().decode(LocalModelIntegrity.SherpaManifest.self, from: Data(contentsOf: url))
        return manifest.models[GrammarModelStore.modelID]!
    }()

    @Test func testCopiesOfTheModelTextMatchThePins() throws {
        for name in ["tokenizer.json", "labels.json", "plausible_pairs.json"] {
            let pinned = try #require(Self.pins.files.first { $0.path == "onnx/\(name)" })
            let copy = GrammarFixtures.root.appendingPathComponent("model-text/\(name)")
            #expect(try LocalModelIntegrity.sha256(of: copy) == pinned.sha256, "\(name)")
        }
    }

    @Test func fixturesWereMadeFromThePinnedModel() {
        for file in Self.pins.files {
            #expect(GrammarFixtures.document.model.sha256[file.path] == file.sha256, "\(file.path)")
        }
    }

    @Test func tokenizerIDsMatchExactly() {
        let tagger = GrammarFixtures.tagger { _, rows in rows.map { _ in [0] } }
        for entry in GrammarFixtures.document.tokenizer {
            #expect(tagger.encodeWord(entry.word) == entry.ids, "“\(entry.word)”")
        }
    }

    @Test func everyPassEncodesTheSameIDsAndStarts() {
        let tagger = GrammarFixtures.tagger { _, rows in rows.map { _ in [0] } }
        for fixture in GrammarFixtures.document.cases {
            for passes in fixture.sentences {
                for pass in passes {
                    let (ids, starts) = tagger.encode(pass.words)
                    #expect(ids == pass.ids, "“\(fixture.input)”")
                    #expect(starts == pass.starts, "“\(fixture.input)”")
                }
            }
        }
    }

    /// Given the model's labels, the guard, the edits and the passes reach the reference output.
    @Test func guardEditsAndPassesReachTheReferenceOutput() throws {
        #expect(GrammarFixtures.document.cases.count >= 40)
        for fixture in GrammarFixtures.document.cases {
            var trace: [[GrammarTagger.Pass]] = []
            let output = try GrammarFixtures.tagger(GrammarFixtures.replay(fixture)).correct(
                fixture.input, vocabulary: Set(fixture.vocabulary), trace: { trace.append($0) }
            )
            #expect(output == fixture.output, "“\(fixture.input)”")
            #expect(trace.count == fixture.sentences.count, "“\(fixture.input)” sentences")
            for (passes, expected) in zip(trace, fixture.sentences) {
                #expect(passes.count == expected.count, "“\(fixture.input)” passes")
                for (pass, want) in zip(passes, expected) {
                    #expect(pass.decisions.map(\.chosen) == want.chosen, "“\(fixture.input)”")
                }
            }
        }
    }
}
