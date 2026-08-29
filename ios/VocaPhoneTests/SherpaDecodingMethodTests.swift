import Foundation
import Testing

/// sherpa-onnx answers an unsupported decoding method with `exit(-1)`, so a
/// wrong value here is not a bad transcript — it is the app disappearing. These
/// are the tests that keep a quality setting from ever reaching a family that
/// cannot survive it.
struct SherpaDecodingMethodTests {
    private static let families: [SherpaFamily] = [
        .nemoTransducer, .senseVoice, .moonshine, .dolphinCtc, .canary, .nemoCtc, .paraformer
    ]

    @Test func everyBundledFamilyStaysOnGreedySearch() {
        for family in Self.families {
            for quality in TranscriptionQuality.allCases {
                #expect(
                    family.decodingMethod(for: quality) == SherpaFamily.greedySearch,
                    "\(family) must stay on greedy search at \(quality)"
                )
            }
        }
    }

    @Test func parakeetNeverEntersTheUnstableNeMoTDTBeamDecoder() {
        #expect(SherpaFamily.nemoTransducer.decodingMethod(for: .fast) == "greedy_search")
        #expect(SherpaFamily.nemoTransducer.decodingMethod(for: .balanced) == "greedy_search")
        #expect(SherpaFamily.nemoTransducer.decodingMethod(for: .accurate) == "greedy_search")
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
                // Not `method == greedy || family.supportsBeamSearch`: with the
                // flag false everywhere that reduces to the first clause and
                // stops asserting anything. What has to hold is that a family
                // is only ever sent a method it can survive, which for anything
                // but the transducer means greedy and nothing else.
                let survivable = family == .nemoTransducer
                    ? [SherpaFamily.greedySearch, "modified_beam_search"]
                    : [SherpaFamily.greedySearch]
                let accepted = survivable.contains(method)
                #expect(
                    accepted,
                    "\(model.id) would be sent \(method), which \(family) cannot accept"
                )
            }
        }
    }

    /// Parakeet's empty-result workaround, and the reason the padded recovery
    /// retry is not a run of exact zeros into a zero-dither feature extractor.
    @Test func onlyParakeetCarriesTheUpstreamEmptyResultDither() {
        #expect(SherpaFamily.nemoTransducer.featureDither == 0.00003)
        for family in Self.families where family != .nemoTransducer {
            #expect(family.featureDither == 0, "\(family) does not need dither")
        }
    }

    /// The value has to reach the samples, not just sit in the catalog: the
    /// pinned runtime has no `feat_config.dither` to pass it to.
    @Test func theDitherActuallyReachesTheWaveform() {
        let silence = [Float](repeating: 0, count: 640)
        let dithered = SherpaFeatureDither.applied(
            to: silence, dither: SherpaFamily.nemoTransducer.featureDither
        )
        let movedSomething = dithered.contains { $0 != 0 }
        let stayedInaudible = dithered.allSatisfy { abs($0) < 0.001 }

        #expect(movedSomething, "a constant window must not stay constant")
        #expect(stayedInaudible, "dither must stay inaudible")
    }

    /// Box-Muller reaches for `log` of a uniform, and a uniform built in `Float`
    /// rounds up to just past 1 about once in every 2^24 draws — one negative
    /// square root, one `NaN` sample, one empty transcript.
    ///
    /// Asserted at the boundary rather than by sampling. One in 2^24 is not
    /// something a test suite finds by drawing: an earlier version of this test
    /// ran twenty blocks of a hundred thousand samples and passed against the
    /// implementation that produced the `NaN`, because the generator it fed was
    /// re-seeded identically each call and never left the same safe prefix.
    @Test func theUniformStaysInsideItsIntervalAtEveryBoundary() {
        let extremes: [UInt64] = [
            0, 1, UInt64.max, UInt64.max - 1,
            // The draw that used to round to exactly 1 in `Float`.
            (1 << 53) - 1, 1 << 53, ((1 << 53) - 1) << 11,
            // And the top of each field the shift can expose.
            (1 << 52) - 1, 1 << 52, ((1 << 52) - 1) << 12, UInt64.max >> 1,
        ]

        for bits in extremes {
            let value = SherpaDitherGenerator.unitInterval(bits: bits)
            #expect(value > 0, "log of \(value) would not be finite")
            #expect(value <= 1, "\(bits) escaped the interval as \(value)")
            #expect((-2 * Foundation.log(value)).squareRoot().isFinite)
        }
    }

    /// The largest draw lands exactly on 1, where `log` is 0 — a magnitude of
    /// zero, not a special case, and specifically not a hair above 1.
    @Test func theLargestDrawIsExactlyOne() {
        #expect(SherpaDitherGenerator.unitInterval(bits: UInt64.max) == 1)
    }

    /// And the end-to-end guarantee the production path actually needs.
    @Test func theDitherNeverWritesANaNIntoTheWaveform() {
        let block = SherpaFeatureDither.applied(
            to: [Float](repeating: 0, count: 200_000),
            dither: SherpaFamily.nemoTransducer.featureDither
        )
        let allFinite = block.allSatisfy(\.isFinite)

        #expect(allFinite, "a dithered sample must always be a number")
    }

    /// The runtime dithers each decode differently, which is what makes the
    /// recovery ladder's second attempt worth its inference. Identical noise
    /// would hand the model identical features and learn nothing.
    @Test func theDitherIsDrawnFreshForEveryDecode() {
        let silence = [Float](repeating: 0, count: 4_096)
        let dither = SherpaFamily.nemoTransducer.featureDither

        let first = SherpaFeatureDither.applied(to: silence, dither: dither)
        let second = SherpaFeatureDither.applied(to: silence, dither: dither)

        #expect(first != second)
    }

    @Test func aFamilyWithoutDitherIsHandedItsSamplesUntouched() {
        let samples: [Float] = [0.1, -0.2, 0.3, 0]
        #expect(SherpaFeatureDither.applied(to: samples, dither: 0) == samples)
    }
}
