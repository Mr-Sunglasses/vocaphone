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
