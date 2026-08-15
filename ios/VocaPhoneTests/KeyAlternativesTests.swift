import Testing
import UIKit

struct KeyAlternativesTests {
    /// Letters with accents and symbols with alternates; nothing else. A key
    /// that opens a popover offering only itself is a key that swallows a
    /// long press for no reason.
    @Test func onlyKeysWithSomethingToOfferOpenAPopover() {
        #expect(KeyAlternatives.hasOptions(for: "a"))
        #expect(KeyAlternatives.hasOptions(for: "A"))
        #expect(KeyAlternatives.hasOptions(for: "$"))
        #expect(!KeyAlternatives.hasOptions(for: "q"))
        #expect(!KeyAlternatives.hasOptions(for: "5"))
        #expect(!KeyAlternatives.hasOptions(for: ""))
    }

    /// The base character leads the list and is the initially highlighted
    /// option, so a finger that never moves types exactly what the key says —
    /// the same contract an ordinary tap has.
    @Test func theBaseCharacterLeadsTheList() {
        let options = KeyAlternatives.options(for: "e", shift: .off)
        #expect(options.first == "e")
        #expect(options.contains("é"))
        #expect(options.count > 1)
    }

    @Test func shiftAndCapsLockProduceUppercaseAlternatives() {
        for shift in [ShiftState.on, .locked] {
            let options = KeyAlternatives.options(for: "o", shift: shift)
            #expect(options.first == "O")
            #expect(options.contains("Ö"))
            #expect(options.allSatisfy { $0 == $0.uppercased() })
        }
    }

    /// "ß".uppercased() is "SS", which is two characters and not something a key
    /// can commit. It is dropped from the shifted plane rather than typed as a
    /// digraph.
    @Test func multiCharacterUppercaseFormsAreDropped() {
        let lower = KeyAlternatives.options(for: "s", shift: .off)
        let upper = KeyAlternatives.options(for: "s", shift: .on)

        #expect(lower.contains("ß"))
        #expect(!upper.contains("SS"))
        #expect(upper.allSatisfy { $0.count == 1 })
        #expect(upper.contains("Š"))
    }

    @Test func aKeyWithNothingToOfferReturnsNothing() {
        #expect(KeyAlternatives.options(for: "q", shift: .off).isEmpty)
        #expect(KeyAlternatives.options(for: ",", shift: .off).isEmpty)
    }

    // MARK: - Popover

    @MainActor
    private func popover(_ options: [String]) -> KeyAlternativesView {
        let metrics = KeyboardMetrics.resolved(
            for: UITraitCollection { $0.verticalSizeClass = .regular },
            preference: .standard
        )
        let palette = KeyboardPalette(isDark: false)
        let view = KeyAlternativesView(palette: palette, metrics: metrics)
        view.show(options, palette: palette, metrics: metrics)
        view.frame = CGRect(origin: .zero, size: view.size(for: options))
        view.layoutIfNeeded()
        return view
    }

    @MainActor
    @Test func slidingMovesTheSelectionAndLiftingCommitsIt() {
        let options = KeyAlternatives.options(for: "a", shift: .off)
        let view = popover(options)

        #expect(view.highlightedOption == options.first)
        #expect(view.highlightOption(atX: view.bounds.width - 8))
        #expect(view.highlightedOption == options.last)
        // Re-reporting the same position is not a change, so it must not fire
        // another selection haptic.
        #expect(!view.highlightOption(atX: view.bounds.width - 8))
    }

    /// A finger dragged past either end keeps the nearest option rather than
    /// losing the selection, which is what the system keyboard does.
    @Test @MainActor func draggingPastTheEdgeClampsToTheNearestOption() {
        let options = KeyAlternatives.options(for: "a", shift: .off)
        let view = popover(options)

        view.highlightOption(atX: -400)
        #expect(view.highlightedOption == options.first)
        view.highlightOption(atX: 4_000)
        #expect(view.highlightedOption == options.last)
    }

    /// The popover has to be big enough to hit. Fingertip-sized options are the
    /// entire reason it exists rather than a longer press cycling in place.
    @Test @MainActor func everyOptionIsAFingertipWide() {
        let options = KeyAlternatives.options(for: "o", shift: .off)
        let view = popover(options)
        let perOption = view.bounds.width / CGFloat(options.count)

        #expect(perOption >= 38)
        #expect(view.bounds.height >= 44)
    }
}
