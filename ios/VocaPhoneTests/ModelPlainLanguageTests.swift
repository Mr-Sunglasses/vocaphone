import Foundation
import Testing

/// The picker leads with these words instead of the upstream model names, so a
/// catalog row without them would reach someone as "Parakeet TDT 0.6B" and
/// nothing else. Mirrors `ModelPlainLanguageTest.kt`.
struct ModelPlainLanguageTests {

    @Test func everyCatalogModelIsExplainedAndNothingElseIs() {
        let catalog = Set(LocalModelCatalog.all.map(\.id))
        #expect(Set(ModelPlainLanguage.byID.keys) == catalog)
    }

    @Test func titlesAndSummariesStayFreeOfModelJargon() {
        let jargon = ["TDT", "CTC", "0.6B", "180M", "int8", "RAM", "WER", "626MB"]
        for (id, plain) in ModelPlainLanguage.byID {
            for word in jargon {
                #expect(!plain.title.contains(word), "\(id) title says \(word)")
                #expect(!plain.summary.contains(word), "\(id) summary says \(word)")
            }
            #expect((1...ModelPlainLanguage.maximumRating).contains(plain.accuracy), "\(id)")
            #expect((1...ModelPlainLanguage.maximumRating).contains(plain.speed), "\(id)")
        }
    }

    @Test func titlesTellTheModelsApart() {
        let titles = ModelPlainLanguage.byID.values.map(\.title)
        #expect(titles.count == Set(titles).count)
    }

    @Test func singleLanguageModelsAreNeverCalledMultilingual() {
        for id in ["giga-am-v3-ru", "parakeet-tdt-0.6b-v2-en", "zipformer-ko", "zipformer-vi"] {
            let plain = try? #require(LocalModelCatalog.descriptor(for: id)).plain
            #expect(plain?.summary.localizedCaseInsensitiveContains("multilingual") == false, "\(id)")
        }
    }

    @Test func onlyAnAllCapitalsTranscriptIsLowerCased() {
        #expect(SherpaFamily.lowercasingCapitals("ÂM LƯỢNG TIVI GIẢM") == "âm lượng tivi giảm")
        #expect(SherpaFamily.lowercasingCapitals("Call NASA today") == "Call NASA today")
        #expect(SherpaFamily.lowercasingCapitals("지하철에서 다리를") == "지하철에서 다리를")
        #expect(SherpaFamily.zipformerTransducer.transcribesInCapitals)
        #expect(!SherpaFamily.nemoTransducer.transcribesInCapitals)
    }

    /// The bridge's token joining, on the tokens sherpa-onnx 1.13.8 returns.
    private static func joined(_ tokens: [String], closingUp: Bool) -> String {
        let copies = tokens.map { UnsafePointer<CChar>(strdup($0)) }
        defer { copies.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var output = [CChar](repeating: 0, count: 256)
        let written = copies.withUnsafeBufferPointer { pointers in
            VocaPhoneSherpaJoinTokens(
                pointers.baseAddress, Int32(pointers.count), closingUp ? 1 : 0,
                &output, Int32(output.count)
            )
        }
        guard written >= 0 else { return "error \(written)" }
        return String(decoding: output.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    @Test func aZipformerTranscriptKeepsTheSpacesItsTokensCarry() {
        // The Korean model's own test_wavs/1.wav; its `text` has no spaces.
        let tokens = [" 지하철", "에서", " 다리", "를", " 벌", "리고", " ", "앉", "지", " 마", "라", "."]
        #expect(Self.joined(tokens, closingUp: false) == "지하철에서 다리를 벌리고 앉지 마라.")
    }

    /// Parakeet Unified's tokens for "Revenue rose 35.3% to $1,200." — the
    /// `text` sherpa-onnx 1.13.8 builds from them reads "to$1,200".
    @Test func aNemoTranscriptKeepsTheSpaceBeforeAnOpeningMark() {
        let tokens = [
            " Re", "ven", "ue", " ro", "se", " ", "3", "5", ".", "3", "%",
            " to", " ", "$", "1", ",", "2", "0", "0", ".",
        ]
        #expect(Self.joined(tokens, closingUp: true) == "Revenue rose 35.3% to $1,200.")
        #expect(Self.joined([" Tom", " ", "&", " Jerry"], closingUp: true) == "Tom & Jerry")
        // A bare word boundary before a closing mark is still closed up.
        #expect(Self.joined([" Yes", " ", ",", " please", " ", "."], closingUp: true) == "Yes, please.")
    }

    @Test func vietnameseAndKoreanGetTheirSpecialists() {
        #expect(LocalModelCatalog.accuracyRanking(for: "vi").first == "zipformer-vi")
        #expect(LocalModelCatalog.accuracyRanking(for: "ko").contains("zipformer-ko"))
        let picks = LocalModelCatalog.recommendations(deviceMemoryGB: 6, languages: ["vi"])
        #expect(picks.first?.model.id == "zipformer-vi")
        let korean = LocalModelCatalog.descriptor(for: "zipformer-ko")
        #expect(korean?.covers("ko") == true)
        #expect(korean?.covers("en") == false)
        #expect(korean?.maker == .nextGenKaldi)
    }
}
