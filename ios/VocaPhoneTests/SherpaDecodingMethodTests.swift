import Testing

/// sherpa-onnx answers an unsupported decoding method with `exit(-1)`, so a
/// wrong value here is not a bad transcript — it is the app disappearing. These
/// are the tests that keep a quality setting from ever reaching a family that
/// cannot survive it.
struct SherpaDecodingMethodTests {
    private static let families: [SherpaFamily] = [
        .nemoTransducer, .senseVoice, .moonshine, .dolphinCtc, .canary, .nemoCtc, .paraformer
    ]

    @Test func onlyTheTransducerFamilyMayBeAskedForBeamSearch() {
        for family in Self.families where family != .nemoTransducer {
            for quality in TranscriptionQuality.allCases {
                #expect(
                    family.decodingMethod(for: quality) == SherpaFamily.greedySearch,
                    "\(family) must stay on greedy search at \(quality)"
                )
            }
        }
    }

    @Test func theTransducerStillWidensItsSearchWhenQualityAsksForIt() {
        #expect(SherpaFamily.nemoTransducer.decodingMethod(for: .fast) == "greedy_search")
        #expect(SherpaFamily.nemoTransducer.decodingMethod(for: .balanced) == "modified_beam_search")
        #expect(SherpaFamily.nemoTransducer.decodingMethod(for: .accurate) == "modified_beam_search")
    }

    @Test func everyModelInTheCatalogResolvesToAMethodItsFamilySurvives() {
        let sherpaModels = LocalModelCatalog.all.filter { $0.engine == .sherpaOnnx }
        #expect(!sherpaModels.isEmpty, "the catalog should still ship sherpa models")
        for model in sherpaModels {
            guard let family = model.sherpaFamily else {
                Issue.record("\(model.id) has no family")
                continue
            }
            for quality in TranscriptionQuality.allCases {
                let method = family.decodingMethod(for: quality)
                #expect(
                    method == SherpaFamily.greedySearch || family.supportsBeamSearch,
                    "\(model.id) would be sent \(method), which \(family) cannot accept"
                )
            }
        }
    }
}
