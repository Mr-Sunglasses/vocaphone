import UIKit

@MainActor
protocol TypingStripViewDelegate: AnyObject {
    func typingStrip(_ strip: TypingStripView, didChoose candidate: TypingCandidate)
}

/// The candidate chips, drawn inside the dictation bar rather than above it.
///
/// A third region would have put the keyboard near 337 pt — appreciably more of
/// the host app than the system keyboard it competes with, to add a feature
/// meant to make it feel more native. Instead the idle bar *becomes* this, and
/// the keyboard gets shorter than it was.
///
/// Scrolls rather than truncating: a candidate clipped to "extraordin…" is one
/// the user cannot judge, and three legible chips that scroll beat three
/// illegible ones that fit. When they do fit — which is nearly always, because
/// three ordinary words are narrower than a phone — the row is centred, so the
/// strip reads as a considered set of three rather than as a list that has been
/// pushed up against the left edge.
final class TypingStripView: UIScrollView {
    weak var chipDelegate: (any TypingStripViewDelegate)?
    private let feedback: any KeyboardFeedbackProviding

    var palette: KeyboardPalette {
        didSet {
            guard palette != oldValue else { return }
            rebuild()
        }
    }

    var metrics: DictationBarMetrics {
        didSet {
            guard metrics != oldValue else { return }
            rebuild()
        }
    }

    private(set) var candidates: [TypingCandidate] = []
    private let row = UIStackView()
    private var buttons: [UIButton] = []
    /// Kept so a reused button can be re-sized when it changes from carrying a
    /// word to carrying a glyph.
    private var minimumWidths: [NSLayoutConstraint] = []
    /// Set when the chips change, so the next layout pass puts the row back at
    /// its centred resting position rather than wherever the last set was
    /// scrolled to.
    private var needsScrollReset = true

    /// The gap between chips. Wide enough that two capsules read as two targets;
    /// narrow enough that three of them still look like one control.
    private static let chipSpacing: CGFloat = 8
    /// A one-letter suggestion in a capsule sized to its text is a dot. Every
    /// chip is at least wide enough to look like something worth aiming at.
    private static let minimumChipWidth: CGFloat = 62
    /// A glyph needs less room than a word to read as a target, and on a 320 pt
    /// strip those points are the difference between the emoji being offered
    /// and being scrolled off the end of the row.
    private static let minimumGlyphChipWidth: CGFloat = 48
    private static let chipTextInset: CGFloat = 14

    init(
        palette: KeyboardPalette,
        metrics: DictationBarMetrics,
        feedback: any KeyboardFeedbackProviding = KeyboardHaptics.shared
    ) {
        self.palette = palette
        self.metrics = metrics
        self.feedback = feedback
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        // A chip row that bounces looks like a mistake; it is a fixed set of
        // three things, not a feed.
        alwaysBounceHorizontal = false
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = Self.chipSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Half the room left over, or nothing at all once the chips overflow.
    ///
    /// Split out from ``layoutSubviews`` because centring by inset is the sort of
    /// arithmetic that is off by half a chip on exactly one device width, and a
    /// pure function can be checked at all of them.
    static func centeringInset(contentWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard contentWidth > 0, availableWidth > contentWidth else { return 0 }
        return ((availableWidth - contentWidth) / 2).rounded(.down)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.centeringInset(
            contentWidth: row.bounds.width,
            availableWidth: bounds.width
        )
        // The inset alone only makes the room scrollable; the offset is what
        // actually moves the row into it.
        if contentInset.left != inset {
            contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            needsScrollReset = true
        }
        if needsScrollReset {
            needsScrollReset = false
            contentOffset = CGPoint(x: -inset, y: 0)
        }
    }

    /// Diffs before it rebuilds. The strip is asked to render on every
    /// keystroke, and rebuilding three button configurations per letter is the
    /// kind of churn that shows up as dropped frames on the oldest device.
    func apply(_ candidates: [TypingCandidate], animated: Bool) {
        guard candidates != self.candidates else { return }
        let wasEmpty = self.candidates.isEmpty
        self.candidates = candidates
        rebuild()
        guard animated, !wasEmpty, !UIAccessibility.isReduceMotionEnabled else { return }
        // Reduce Motion swaps immediately; the chips are information, and the
        // crossfade is decoration on top of it.
        UIView.transition(
            with: self,
            duration: 0.16,
            options: [.transitionCrossDissolve, .allowUserInteraction],
            animations: {}
        )
    }

    private func rebuild() {
        while buttons.count < candidates.count {
            let button = UIButton(type: .system)
            button.tag = buttons.count
            button.addTarget(self, action: #selector(chipTapped), for: .touchUpInside)
            // A chip that does not react under the thumb reads as a label the
            // user has failed to hit. UIKit dims a plain button's title on its
            // own, which on an accent fill is invisible; this moves the whole
            // capsule instead.
            button.configurationUpdateHandler = { button in
                let isPressed = button.isHighlighted
                button.alpha = isPressed ? 0.72 : 1
                button.transform = isPressed
                    ? CGAffineTransform(scaleX: 0.95, y: 0.95)
                    : .identity
            }
            row.addArrangedSubview(button)
            let minimum = button.widthAnchor
                .constraint(greaterThanOrEqualToConstant: Self.minimumChipWidth)
            minimum.isActive = true
            minimumWidths.append(minimum)
            buttons.append(button)
        }
        for (index, button) in buttons.enumerated() {
            guard index < candidates.count else {
                button.isHidden = true
                continue
            }
            button.isHidden = false
            minimumWidths[index].constant = candidates[index].kind == .emoji
                ? Self.minimumGlyphChipWidth
                : Self.minimumChipWidth
            configure(button, with: candidates[index])
        }
        needsScrollReset = true
        setNeedsLayout()
    }

    private func configure(_ button: UIButton, with candidate: TypingCandidate) {
        var configuration = UIButton.Configuration.plain()
        // The literal is quoted, exactly as the system keyboard quotes the word
        // it is about to take away. The quotes are the affordance: they say
        // "this is what you typed", and iOS has trained everyone to read them.
        // The literal and the revert are both quoted, exactly as the system
        // keyboard quotes a word it is about to take away or has just taken.
        // The revert carries a leading undo arrow as well, because by the time
        // it appears the replacement is already in the document and the chip has
        // to say "put it back" rather than "keep this".
        configuration.title = switch candidate.kind {
        case .literal: "“\(candidate.text)”"
        case .revert: "↩ “\(candidate.text)”"
        default: candidate.text
        }
        let isEmoji = candidate.kind == .emoji
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: Self.chipTextInset,
            bottom: 0,
            trailing: Self.chipTextInset
        )
        configuration.titleLineBreakMode = .byTruncatingTail

        let isEmphasised = candidate.isEmphasised
        let fill = isEmphasised ? palette.accentKey : palette.chipBackground
        configuration.background.backgroundColor = fill
        // A hairline around the quiet chips. The fill alone is a wash on the bar
        // it sits on, and the edge is what turns it into an object: it gives the
        // capsule a boundary at the exact place the finger is aiming for. The
        // emphasised chip is solid accent and needs no help being seen.
        configuration.background.strokeColor = isEmphasised ? .clear : palette.chipBorder
        configuration.background.strokeWidth = isEmphasised ? 0 : 1 / max(traitCollection.displayScale, 1)
        let label = isEmphasised
            ? ContrastMath.legibleLabel(on: palette.accentKey)
            : palette.label
        configuration.baseForegroundColor = label
        let size = metrics.bodyFontSize + 2.5
        configuration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                // Medium rather than regular: a chip is a control, and at this
                // size regular reads as body text that happens to be in a pill.
                // A glyph rather than a word: it carries no weight and reads
                // at the size the keys use, not the size of a label.
                outgoing.font = isEmoji
                    ? .systemFont(ofSize: size + 4)
                    : .systemFont(ofSize: size, weight: isEmphasised ? .semibold : .medium)
                outgoing.foregroundColor = label
                return outgoing
            }
        button.configuration = configuration
        button.accessibilityLabel = candidate.text
        button.accessibilityHint = Self.hint(for: candidate)
    }

    /// What the chip does, said plainly. VoiceOver reads the word from the
    /// label; the hint is the part that says why it is on screen.
    ///
    /// Candidate *changes* are deliberately never announced: that would talk
    /// over every keystroke and make the keyboard unusable with VoiceOver on.
    static func hint(for candidate: TypingCandidate) -> String {
        switch candidate.kind {
        case .literal: "Keeps what you typed."
        case .completion: "Completes the word."
        case .correction: "Replaces the word."
        case .prediction: "Inserts this word next."
        case .emoji: "Replaces the word with this emoji."
        case .swipeAlternate: "Replaces the swiped word."
        case .revert: "Undoes the autocorrect and restores what you typed."
        }
    }

    @objc private func chipTapped(_ sender: UIButton) {
        guard sender.tag < candidates.count else { return }
        // A chip replaces a whole word, which is a bigger edit than any key
        // makes. Silence here, next to keys that tap back, reads as a chip that
        // did not register.
        feedback.selectionChanged()
        chipDelegate?.typingStrip(self, didChoose: candidates[sender.tag])
    }
}

#if DEBUG
import SwiftUI

// MARK: - Previews

// Zero to three chips, light and dark. Three ordinary words nearly always fit
// and the row centres; the long set is the case that scrolls, which is the
// behaviour this view exists for and the one nobody had looked at.

private struct StripPreview: View {
    var candidates: [TypingCandidate]
    var dark = false

    var body: some View {
        let metrics = KeyboardPreviewEnvironment.barMetrics()
        return KeyboardViewPreview {
            TypingStripView(
                palette: KeyboardPreviewEnvironment.palette(dark: dark),
                metrics: metrics
            )
        } configure: { strip in
            strip.palette = KeyboardPreviewEnvironment.palette(dark: dark)
            strip.apply(candidates, animated: false)
        }
        .frame(width: 360, height: metrics.stripHeight)
        .background(Color(KeyboardPreviewEnvironment.palette(dark: dark).background))
    }
}

#Preview("Typing strip — 0 to 3 chips", traits: .sizeThatFitsLayout) {
    VStack(spacing: 12) {
        StripPreview(candidates: [])
        StripPreview(candidates: Array(KeyboardPreviewEnvironment.candidates.prefix(1)))
        StripPreview(candidates: Array(KeyboardPreviewEnvironment.candidates.prefix(2)))
        StripPreview(candidates: KeyboardPreviewEnvironment.candidates)
    }
    .padding()
}

#Preview("Typing strip — dark", traits: .sizeThatFitsLayout) {
    VStack(spacing: 12) {
        StripPreview(candidates: KeyboardPreviewEnvironment.candidates, dark: true)
        StripPreview(candidates: [], dark: true)
    }
    .padding()
}

/// One-letter and glyph chips have their own minimum widths, and a long set is
/// the only case that scrolls rather than fits.
#Preview("Typing strip — short, glyph and overflowing", traits: .sizeThatFitsLayout) {
    VStack(spacing: 12) {
        StripPreview(candidates: [
            TypingCandidate(text: "a", kind: .completion),
            TypingCandidate(text: "I", kind: .completion),
            TypingCandidate(text: "🎉", kind: .emoji),
        ])
        StripPreview(candidates: [
            TypingCandidate(text: "internationalization", kind: .completion),
            TypingCandidate(text: "interoperability", kind: .completion),
            TypingCandidate(text: "interchangeable", kind: .completion),
        ])
    }
    .padding()
}
#endif
