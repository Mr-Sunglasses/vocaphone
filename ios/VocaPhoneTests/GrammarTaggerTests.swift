import Foundation
import Testing

/// The rules the parity fixtures do not reach on their own: a model that
/// proposes something the guard must refuse. Mirrors GrammarTaggerTest.kt.
struct GrammarTaggerTests {
    final class Calls: @unchecked Sendable {
        var count = 0
    }

    /// A model that proposes `propose` for every word whose text matches, and KEEP elsewhere.
    private func model(_ propose: [String: String] = [:], calls: Calls? = nil) -> GrammarTagger {
        let encoded = propose.keys.map { word in
            (ids: GrammarFixtures.tokenizer.encode(" " + word).map(Int64.init), label: propose[word]!)
        }
        return GrammarFixtures.tagger { ids, rows in
            calls?.count += 1
            return rows.indices.map { r in
                let start = Int(rows[r])
                let end = r + 1 < rows.count ? Int(rows[r + 1]) : ids.count
                let word = Array(ids[start..<end])
                return GrammarFixtures.row(encoded.first { $0.ids == word }?.label ?? "KEEP")
            }
        }
    }

    @Test func protectedSpansNumbersAndNamesAreNeverChanged() throws {
        let tagger = model([
            "example.com": "DELETE", "7:30": "REPLACE_the", "42": "DELETE",
            "Kevin": "REPLACE_the", "iPhone": "REPLACE_phone",
        ])
        for text in [
            "Check example.com today.", "Meet at 7:30 please.", "I owe you 42 dollars.",
            "Tell Kevin hello.", "My iPhone died.",
        ] {
            #expect(try tagger.correct(text) == text)
        }
    }

    @Test func customVocabularyIsNeverChanged() throws {
        // A replacement the guard would otherwise accept: one letter off.
        let tagger = model(["tomorow": "REPLACE_tomorrow"])
        #expect(try tagger.correct("See you tomorow.") == "See you tomorrow.")
        #expect(try tagger.correct("See you tomorow.", vocabulary: ["Tomorow"]) == "See you tomorow.")
    }

    @Test func nonLatinWordsTheModelMayNotTouch() throws {
        let tagger = model(["café": "REPLACE_cafe", "👍": "DELETE"])
        #expect(try tagger.correct("Meet at the café 👍") == "Meet at the café 👍")
        #expect(try tagger.correct("今天天气很好。") == "今天天气很好。")
    }

    @Test func implausibleReplacementsAndAppendsAreRefused() throws {
        let tagger = model(["cat": "REPLACE_the", "home": "APPEND_tomorrow", "noon": "APPEND_very"])
        #expect(try tagger.correct("The cat went home at noon.") == "The cat went home at noon.")
    }

    @Test func aPrepositionBeforeANumberOrNameStays() throws {
        let tagger = model(["at": "REPLACE_by"])
        #expect(try tagger.correct("Meet at 5 pm.") == "Meet at 5 pm.")
        #expect(try tagger.correct("Meet at Priya's.") == "Meet at Priya's.")
    }

    @Test func itStopsAfterThreePasses() throws {
        // A model that never settles: every pass appends another "the".
        let calls = Calls()
        _ = try model(["go": "APPEND_the"], calls: calls).correct("I go.")
        #expect(calls.count == GrammarTagger.maxPasses)
    }

    @Test func itStopsAsSoonAsAPassChangesNothing() throws {
        let calls = Calls()
        _ = try model(calls: calls).correct("Nothing to fix here.")
        #expect(calls.count == 1)
    }

    @Test func aPassedDeadlineLeavesTheRestOfTheTextAlone() throws {
        let tagger = model(["don't": "REPLACE_doesn't"])
        let past = DispatchTime.now().uptimeNanoseconds - 1
        #expect(try tagger.correct("He don't know. She don't care.", deadline: past) == "He don't know. She don't care.")
        #expect(try tagger.correct("He don't know. She don't care.") == "He doesn't know. She doesn't care.")
    }

    @Test func textWithNoLettersComesBackAsItWas() throws {
        for text in ["", "...", "42", "👍 🎉"] {
            #expect(try model().correct(text) == text)
        }
    }

    @Test func longSentencesAreChunkedUnderTheModelsLimit() throws {
        let calls = Calls()
        let sentence = Array(repeating: "word", count: 400).joined(separator: " ") + "."
        #expect(try model(calls: calls).correct(sentence) == sentence)
        #expect(calls.count >= 3)
    }

    @Test func editDistanceIsLevenshtein() {
        #expect(GrammarTagger.editDistance("same", "same") == 0)
        #expect(GrammarTagger.editDistance("recieve", "receive") == 2)
        #expect(GrammarTagger.editDistance("kitten", "sitting") == 3)
        #expect(GrammarTagger.editDistance("", "abc") == 3)
    }
}
