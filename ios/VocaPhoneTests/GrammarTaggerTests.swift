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

    /// Greptile on #417: a vocabulary word protects either apostrophe.
    @Test func vocabularyMatchesAcrossApostrophes() throws {
        let tagger = model(["don't": "REPLACE_doesn't"])
        #expect(try tagger.correct("He don’t know.", vocabulary: ["don't"]) == "He don’t know.")
        #expect(try tagger.correct("He don't know.", vocabulary: ["don’t"]) == "He don't know.")
        #expect(try tagger.correct("He don’t know.") == "He doesn’t know.")
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

    // MARK: - Greptile on #414 and #416

    /// A sentence long enough for two chunks, with a name opening the second.
    private func boundarySentence() -> String {
        var words = ["So"]
        var tokens = GrammarFixtures.tokenizer.encode(" So").count
        let filler = ["and", "then", "we", "went"]
        while true {
            let next = filler[words.count % filler.count]
            let count = GrammarFixtures.tokenizer.encode(" " + next).count
            if tokens + count > GrammarTagger.maxTokens { break }
            words.append(next)
            tokens += count
        }
        return (words + ["Mark", "left", "at", "noon."]).joined(separator: " ")
    }

    @Test func aNameAtAChunkBoundaryIsStillAName() throws {
        let sentence = boundarySentence()
        let calls = Calls()
        #expect(try model(["Mark": "REPLACE_make"], calls: calls).correct(sentence) == sentence)
        #expect(calls.count == 2, "two chunks")
    }

    @Test func aWordTooLongForTheModelIsNeverSentToIt() throws {
        let url = "https://example.com/" + (0..<60).map { "segment\($0)" }.joined(separator: "/")
        let longest = Calls()
        let tagger = GrammarFixtures.tagger { ids, rows in
            longest.count = max(longest.count, ids.count)
            return rows.map { _ in GrammarFixtures.row("KEEP") }
        }
        #expect(try tagger.correct("He don't know where \(url) went.") == "He don't know where \(url) went.")
        #expect(longest.count <= GrammarTagger.maxTokens + 1)
    }

    @Test func aDeadlineMidSentenceLeavesTheRemainingChunksAlone() throws {
        let long = boundarySentence().replacingOccurrences(of: "noon.", with: "noon and he don't know.")
        let calls = Calls()
        let dont = GrammarFixtures.tokenizer.encode(" don't").map(Int64.init)
        let tagger = GrammarFixtures.tagger { ids, rows in
            calls.count += 1
            // The first chunk eats the whole budget.
            if calls.count == 1 { Thread.sleep(forTimeInterval: 0.08) }
            return rows.indices.map { r in
                let end = r + 1 < rows.count ? Int(rows[r + 1]) : ids.count
                return GrammarFixtures.row(Array(ids[Int(rows[r])..<end]) == dont ? "REPLACE_doesn't" : "KEEP")
            }
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 50_000_000
        #expect(try tagger.correct(long, deadline: deadline) == long)
        #expect(calls.count == 1)
    }

    /// Above `GrammarTagger.keepBias`, below `GrammarTagger.sureKeepBias`.
    private static let contestedScore: Float = 3.5

    /// A model that scores "tomorow" → "tomorrow" between the two KEEP biases:
    /// Balanced (3) makes the fix, Only sure fixes (4) keeps the word. The
    /// fixtures replay labels at a score of 10, which pass under either bias.
    private func contested(keepBias: Float = GrammarTagger.keepBias) -> GrammarTagger {
        let typo = GrammarFixtures.tokenizer.encode(" tomorow").map(Int64.init)
        return GrammarFixtures.tagger(keepBias: keepBias) { ids, rows in
            rows.indices.map { r in
                let start = Int(rows[r])
                let end = r + 1 < rows.count ? Int(rows[r + 1]) : ids.count
                return Array(ids[start..<end]) == typo
                    ? GrammarFixtures.row("REPLACE_tomorrow", score: Self.contestedScore)
                    : GrammarFixtures.row("KEEP")
            }
        }
    }

    /// Greptile on #435: the per-call bias decides, and only for that call.
    @Test func theBiasPassedToACallDecidesThatCallOnly() throws {
        let typo = "See you tomorow."
        let fixed = "See you tomorrow."
        let tagger = contested()

        #expect(try tagger.correct(typo) == fixed)
        #expect(try tagger.correct(typo, bias: GrammarTagger.sureKeepBias) == typo)
        #expect(try tagger.correct(typo) == fixed)
        #expect(try tagger.correct(typo, bias: GrammarTagger.keepBias) == fixed)
    }

    @Test func aTaggerBuiltForSureFixesCanStillBeAskedForBalanced() throws {
        let typo = "See you tomorow."
        let fixed = "See you tomorrow."
        let tagger = contested(keepBias: GrammarTagger.sureKeepBias)

        #expect(try tagger.correct(typo) == typo)
        #expect(try tagger.correct(typo, bias: GrammarTagger.keepBias) == fixed)
        #expect(try tagger.correct(typo) == typo)
    }
}
