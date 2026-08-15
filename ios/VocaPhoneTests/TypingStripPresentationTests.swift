import Testing
import UIKit

/// The strip lives inside the dictation bar, which means it has to disappear
/// completely the moment a session needs that row — and never leave the bar
/// empty when it does not.
@MainActor
struct TypingStripPresentationTests {
    private static func model(
        _ state: SessionState,
        candidates: [TypingCandidate] = [],
        hasFullAccess: Bool = true,
        canUndo: Bool = false
    ) -> DictationBarModel {
        DictationBarModel.make(
            DictationContext(
                state: state,
                hasFullAccess: hasFullAccess,
                canUndo: canUndo,
                candidates: candidates
            )
        )
    }

    private static let candidates = [
        TypingCandidate(text: "teh", kind: .literal),
        TypingCandidate(text: "the", kind: .correction, isEmphasised: true),
        TypingCandidate(text: "ten", kind: .completion),
    ]

    /// Candidates are irrelevant while a transcript is arriving, and competing
    /// for that row would be noise.
    @Test func onlyTheIdleBarEverShowsCandidates() {
        for state in SessionState.allCases {
            let model = Self.model(state, candidates: Self.candidates)
            let showsCandidates: Bool = if case .candidates = model.body { true } else { false }
            #expect(showsCandidates == (state == .idle || state == .canceled || state == .expired))
        }
    }

    /// The keyboard never shows an empty strip. With nothing to suggest, the
    /// row goes back to the language and style pickers.
    @Test func anIdleBarWithNoCandidatesShowsThePickers() {
        #expect(Self.model(.idle).body == .controls)
        #expect(Self.model(.idle, candidates: Self.candidates).body == .candidates(Self.candidates))
    }

    /// A finished insertion keeps its headline and its Undo button: "Text
    /// inserted" with an undo still available is not the moment to start
    /// offering candidates for the next word.
    @Test func aFinishedInsertionKeepsItsHeadlineRatherThanChips() {
        let model = Self.model(.completed, candidates: Self.candidates, canUndo: true)
        #expect(model.layout == .status)
        #expect(model.body == .controls)
        #expect(model.secondaries.contains { $0.action == .undo })
    }

    /// Without Full Access the bar has one job — explaining how to turn it on —
    /// and the strip must not take that row.
    @Test func theLockedBarIsNeverAStrip() {
        let model = Self.model(.idle, candidates: Self.candidates, hasFullAccess: false)
        #expect(model.layout == .status)
        #expect(model.body != .candidates(Self.candidates))
    }

    @Test func onlyTheIdleBarUsesTheStripLayout() {
        for state in SessionState.allCases {
            let model = Self.model(state, candidates: Self.candidates)
            let isStrip = model.layout == .strip
            #expect(isStrip == (state == .idle || state == .canceled || state == .expired))
        }
    }

    // MARK: - The view

    private static func makeStrip(
        _ candidates: [TypingCandidate],
        width: CGFloat = 260
    ) -> TypingStripView {
        let metrics = DictationBarMetrics.resolved(
            for: UITraitCollection { $0.verticalSizeClass = .regular },
            preference: .standard
        )
        let strip = TypingStripView(
            palette: KeyboardPalette(isDark: false),
            metrics: metrics
        )
        strip.frame = CGRect(x: 0, y: 0, width: width, height: metrics.chipHeight)
        strip.apply(candidates, animated: false)
        strip.layoutIfNeeded()
        return strip
    }

    /// The chips as drawn, in the strip's own `bounds` — which for a scroll view
    /// already carries the content offset in its origin, so the two are directly
    /// comparable and nothing has to be subtracted by hand.
    private static func drawnChipBounds(in strip: TypingStripView) -> CGRect {
        let chips = buttons(in: strip)
        guard let first = chips.first, let last = chips.last else { return .null }
        return first.frame.union(last.frame)
    }

    private static func buttons(in view: UIView) -> [UIButton] {
        (view.subviews + view.subviews.flatMap { $0.subviews })
            .compactMap { $0 as? UIButton }
            .filter { !$0.isHidden }
    }

    @Test func oneVisibleChipPerCandidate() {
        #expect(Self.buttons(in: Self.makeStrip(Self.candidates)).count == 3)
        #expect(Self.buttons(in: Self.makeStrip([Self.candidates[0]])).count == 1)
        #expect(Self.buttons(in: Self.makeStrip([])).isEmpty)
    }

    /// The strip re-renders on every keystroke. Rebuilding three button
    /// configurations per letter is the churn that shows up as dropped frames on
    /// the oldest device.
    @Test func identicalCandidatesDoNotRebuildChips() {
        let strip = Self.makeStrip(Self.candidates)
        let before = Self.buttons(in: strip)
        for _ in 0..<20 { strip.apply(Self.candidates, animated: false) }
        strip.layoutIfNeeded()
        let after = Self.buttons(in: strip)
        #expect(after.count == before.count)
        // The same button objects, not replacements that happen to match.
        #expect(zip(before, after).allSatisfy { $0 === $1 })
    }

    /// VoiceOver reads the word from the label; the hint is the part that says
    /// why the chip is on screen. Candidate *changes* are never announced —
    /// that would talk over every keystroke.
    @Test func everyChipCarriesAWordAndAnExplanation() {
        let strip = Self.makeStrip(Self.candidates)
        for button in Self.buttons(in: strip) {
            #expect(!(button.accessibilityLabel ?? "").isEmpty)
            #expect(!(button.accessibilityHint ?? "").isEmpty)
        }
        #expect(TypingStripView.hint(for: Self.candidates[0]).contains("typed"))
        #expect(TypingStripView.hint(for: Self.candidates[1]).contains("Replaces"))
    }

    /// The literal is quoted, exactly as the system keyboard quotes the word it
    /// is about to take away. The quotes are the affordance.
    @Test func theLiteralChipIsQuoted() {
        let strip = Self.makeStrip(Self.candidates)
        let titles = Self.buttons(in: strip).map { $0.configuration?.title ?? "" }
        #expect(titles.first == "“teh”")
        #expect(titles.contains("the"))
    }

    // MARK: - Centring

    @Test func theInsetIsHalfTheRoomLeftOver() {
        #expect(TypingStripView.centeringInset(contentWidth: 200, availableWidth: 300) == 50)
        // An odd remainder rounds down rather than landing on a half pixel.
        #expect(TypingStripView.centeringInset(contentWidth: 201, availableWidth: 300) == 49)
    }

    /// Once the chips overflow there is nothing to centre, and an inset would
    /// push the first candidate off the leading edge of a strip the user now has
    /// to scroll.
    @Test func chipsThatOverflowAreNotInset() {
        #expect(TypingStripView.centeringInset(contentWidth: 400, availableWidth: 300) == 0)
        #expect(TypingStripView.centeringInset(contentWidth: 300, availableWidth: 300) == 0)
        // Before the first layout there is no content to measure.
        #expect(TypingStripView.centeringInset(contentWidth: 0, availableWidth: 300) == 0)
    }

    /// Three ordinary words are narrower than a phone, so the everyday case is
    /// the centred one — that is the whole reason the arithmetic exists.
    @Test func threeShortCandidatesSitInTheMiddleOfTheStrip() {
        for width in [320, 375, 393, 430] as [CGFloat] {
            let strip = Self.makeStrip(Self.candidates, width: width)
            let drawn = Self.drawnChipBounds(in: strip)
            #expect(abs(drawn.midX - strip.bounds.midX) <= 1)
            // Room on both sides, not a row that happens to be centred because
            // it fills the strip.
            #expect(drawn.minX > strip.bounds.minX)
            #expect(drawn.maxX < strip.bounds.maxX)
        }
    }

    /// A single prediction is centred too, rather than sitting alone against the
    /// leading edge with the whole row empty beside it.
    @Test func oneCandidateIsCentredRatherThanLeftAligned() {
        let strip = Self.makeStrip([TypingCandidate(text: "the", kind: .prediction)])
        let drawn = Self.drawnChipBounds(in: strip)
        #expect(abs(drawn.midX - strip.bounds.midX) <= 1)
    }

    /// Candidates that do not fit keep the old behaviour: start at the leading
    /// edge and scroll, because a word the user cannot read is worse than one
    /// they have to reach for.
    @Test func candidatesTooWideToFitStartAtTheLeadingEdge() {
        let long = [
            TypingCandidate(text: "internationalisation", kind: .literal),
            TypingCandidate(text: "internationalising", kind: .correction, isEmphasised: true),
            TypingCandidate(text: "internationalised", kind: .completion),
        ]
        let strip = Self.makeStrip(long, width: 320)
        #expect(strip.contentInset.left == 0)
        #expect(Self.drawnChipBounds(in: strip).minX == strip.bounds.minX)
    }

    /// A short word in a capsule sized to its text is a dot on a wide strip.
    @Test func everyChipIsWideEnoughToAimAt() {
        let strip = Self.makeStrip([
            TypingCandidate(text: "a", kind: .literal),
            TypingCandidate(text: "I", kind: .correction, isEmphasised: true),
        ])
        for button in Self.buttons(in: strip) {
            #expect(button.bounds.width >= 60)
        }
    }

    @Test func chipsStayInsideTheStrip() {
        let strip = Self.makeStrip(Self.candidates)
        for button in Self.buttons(in: strip) {
            #expect(button.bounds.height <= strip.bounds.height + 0.5)
        }
    }
}
