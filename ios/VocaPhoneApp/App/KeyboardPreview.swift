import SwiftUI
import UIKit

/// A live, non-interactive picture of the keyboard being configured.
///
/// The height setting used to be three words and a paragraph of prose. Nobody
/// can picture 39 pt against 49 pt from prose, and the only way to find out was
/// to leave Settings, open another app, and type something. The keyboard's own
/// views already build outside the extension, so showing the real thing costs
/// almost nothing — and it is the real thing, not a drawing of it: change the
/// height or turn suggestions off and this redraws exactly as the keyboard will.
struct KeyboardPreview: View {
    var preference: KeyboardHeightPreference
    var showsSuggestions: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        KeyboardPreviewRepresentable(
            preference: preference,
            showsSuggestions: showsSuggestions,
            isDark: colorScheme == .dark
        )
        .frame(height: KeyboardPreviewRepresentable.height(for: preference))
        .clipShape(RoundedRectangle(cornerRadius: VocaMetrics.fieldRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Keyboard preview")
        .accessibilityValue(
            "\(preference.displayName) height, suggestions "
                + (showsSuggestions ? "on" : "off")
        )
    }
}

private struct KeyboardPreviewRepresentable: UIViewRepresentable {
    let preference: KeyboardHeightPreference
    let showsSuggestions: Bool
    let isDark: Bool

    /// The same arithmetic the extension does, so the preview is the height the
    /// keyboard will actually be.
    static let chromeInset: CGFloat = 6
    static let chromeSpacing: CGFloat = 7

    static func height(for preference: KeyboardHeightPreference) -> CGFloat {
        let traits = UITraitCollection { $0.verticalSizeClass = .regular }
        let grid = KeyboardMetrics.resolved(for: traits, preference: preference)
        let bar = DictationBarMetrics.resolved(for: traits, preference: preference)
        return 2 * chromeInset + bar.stripHeight + chromeSpacing + grid.gridHeight
    }

    func makeUIView(context: Context) -> KeyboardPreviewContainer {
        KeyboardPreviewContainer()
    }

    func updateUIView(_ view: KeyboardPreviewContainer, context: Context) {
        view.configure(
            preference: preference,
            showsSuggestions: showsSuggestions,
            isDark: isDark
        )
    }
}

/// Hosts the two real keyboard views and lays them out the way the extension
/// does. Touch is off: this is a picture that happens to be made of the same
/// parts, and a preview that typed into nothing would only confuse.
final class KeyboardPreviewContainer: UIView {
    private var grid: KeyGridView?
    private var bar: DictationBarView?
    private var rendered: (KeyboardHeightPreference, Bool, Bool)?

    /// Something recognisable rather than a real correction: the preview must
    /// never look like it is proposing to change text the user has not typed.
    private static let sampleCandidates = [
        TypingCandidate(text: "hello", kind: .completion),
        TypingCandidate(text: "help", kind: .completion),
        TypingCandidate(text: "hell", kind: .completion),
    ]

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        preference: KeyboardHeightPreference,
        showsSuggestions: Bool,
        isDark: Bool
    ) {
        guard rendered == nil || rendered! != (preference, showsSuggestions, isDark) else {
            return
        }
        rendered = (preference, showsSuggestions, isDark)

        let traits = UITraitCollection { $0.verticalSizeClass = .regular }
        let palette = KeyboardPalette(isDark: isDark)
        let gridMetrics = KeyboardMetrics.resolved(for: traits, preference: preference)
        let barMetrics = DictationBarMetrics.resolved(for: traits, preference: preference)
        backgroundColor = palette.background

        let grid = self.grid ?? {
            let created = KeyGridView(metrics: gridMetrics, palette: palette)
            addSubview(created)
            self.grid = created
            return created
        }()
        grid.metrics = gridMetrics
        grid.palette = palette
        grid.showsGlobeKey = true
        grid.shiftState = .off

        let bar = self.bar ?? {
            let created = DictationBarView(metrics: barMetrics, palette: palette)
            addSubview(created)
            self.bar = created
            return created
        }()
        bar.metrics = barMetrics
        bar.palette = palette
        bar.apply(
            DictationBarModel.make(
                DictationContext(
                    state: .idle,
                    candidates: showsSuggestions ? Self.sampleCandidates : []
                )
            ),
            animated: false
        )
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let grid, let bar, let rendered else { return }
        let traits = UITraitCollection { $0.verticalSizeClass = .regular }
        let gridMetrics = KeyboardMetrics.resolved(for: traits, preference: rendered.0)
        let barMetrics = DictationBarMetrics.resolved(for: traits, preference: rendered.0)
        let inset = KeyboardPreviewRepresentable.chromeInset
        let spacing = KeyboardPreviewRepresentable.chromeSpacing
        let width = bounds.width - 2 * inset
        bar.frame = CGRect(x: inset, y: inset, width: width, height: barMetrics.stripHeight)
        grid.frame = CGRect(
            x: inset,
            y: bar.frame.maxY + spacing,
            width: width,
            height: gridMetrics.gridHeight
        )
    }
}
