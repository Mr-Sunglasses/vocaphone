import Testing
import UIKit

struct KeyAlternativesTests {
    // MARK: - Every layout can type its own language

    /// A layout whose alphabet contains a letter that is on no key and behind
    /// no key cannot type its own language.
    ///
    /// This is the test the Russian layout was written against and the reason
    /// ``TypingLayout/alphabet`` exists at all. Thirty-three letters do not fit
    /// on thirty-one keys, so ё and ъ went behind е and ь — and the only thing
    /// standing between that decision and a keyboard that silently cannot type
    /// «объём» is this loop. It costs nothing and it guards every language
    /// added after this one, which is the point: adding a layout is adding a
    /// catalogue entry, and this is what makes that safe.
    @Test func everyLayoutCanReachEveryLetterOfItsOwnAlphabet() {
        for layout in TypingLayout.catalogue {
            let onKeys = Set(layout.rows.joined())
            for letter in layout.alphabet where !onKeys.contains(letter) {
                let base = String(letter)
                // Reachable by holding some key whose popover offers it.
                let carriers = onKeys.filter { key in
                    KeyAlternatives.options(for: String(key), shift: .off).contains(base)
                }
                #expect(
                    !carriers.isEmpty,
                    "\(layout.displayName): \(base) is on no key and behind no key"
                )
            }
        }
    }

    /// ё and ъ are letters, not decorations.
    ///
    /// Everything else in the accent table is an ergonomic extra — a Latin
    /// keyboard types "cafe" without ever opening a popover. These two are the
    /// only way to type them at all, which is why they are asserted by name
    /// rather than left to the loop above.
    @Test func russianHidesItsTwoExtraLettersWhereIOSDoes() {
        #expect(KeyAlternatives.options(for: "е", shift: .off).contains("ё"))
        #expect(KeyAlternatives.options(for: "ь", shift: .off).contains("ъ"))
        #expect(KeyAlternatives.options(for: "Е", shift: .on).contains("Ё"))
    }

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
