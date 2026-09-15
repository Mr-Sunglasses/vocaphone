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
    /// The row above the keys is the SwiftUI surface when compact controls are
    /// on — the default — and the older UIKit bar otherwise. Drawing the bar
    /// here while the keyboard shows the compact row previewed a keyboard
    /// nobody has.
    var usesCompactControls: Bool = KeyboardPreferences.compactControlsEnabled

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var surface = DictationSurfaceState()

    var body: some View {
        KeyboardPreviewRepresentable(
            preference: preference,
            showsSuggestions: showsSuggestions,
            isDark: colorScheme == .dark,
            showsBar: !usesCompactControls
        )
        .overlay(alignment: .top) {
            if usesCompactControls {
                DictationSurfaceView(state: surface)
                    .frame(height: KeyboardPreviewRepresentable.stripAreaHeight(for: preference))
                    .allowsHitTesting(false)
            }
        }
        .onAppear { syncSurface() }
        .onChange(of: showsSuggestions) { syncSurface() }
        .onChange(of: colorScheme) { syncSurface() }
        .frame(height: KeyboardPreviewRepresentable.height(for: preference))
        .clipShape(RoundedRectangle(cornerRadius: VocaMetrics.fieldRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Keyboard preview")
        .accessibilityValue(
            "\(preference.displayName) height, suggestions "
                + (showsSuggestions ? "on" : "off")
        )
    }

    /// Idle, as the keyboard is before anyone speaks, with the same model the
    /// extension draws its buttons from.
    private func syncSurface() {
        let isDark = colorScheme == .dark
        surface.state = .idle
        surface.isDark = isDark
        surface.typing.isDark = isDark
        surface.showsGlobeKey = true
        surface.usesCompactControls = true
        let model = DictationBarModel.make(DictationContext(state: .idle))
        surface.primarySymbol = model.primary.symbol
        surface.primaryIsEnabled = model.primary.isEnabled
        surface.candidates = showsSuggestions ? KeyboardPreviewContainer.sampleCandidates : []
    }
}

private struct KeyboardPreviewRepresentable: UIViewRepresentable {
    let preference: KeyboardHeightPreference
    let showsSuggestions: Bool
    let isDark: Bool
    let showsBar: Bool

    /// The same arithmetic the extension does, so the preview is the height the
    /// keyboard will actually be.
    static let chromeInset: CGFloat = 6
    static let chromeSpacing: CGFloat = 12

    static func height(for preference: KeyboardHeightPreference) -> CGFloat {
        let traits = UITraitCollection { $0.verticalSizeClass = .regular }
        let grid = KeyboardMetrics.resolved(for: traits, preference: preference)
        let bar = DictationBarMetrics.resolved(for: traits, preference: preference)
        return 2 * chromeInset + bar.stripHeight + chromeSpacing + grid.gridHeight
    }

    /// The band above the keys, where the dictation row sits.
    static func stripAreaHeight(for preference: KeyboardHeightPreference) -> CGFloat {
        let traits = UITraitCollection { $0.verticalSizeClass = .regular }
        let bar = DictationBarMetrics.resolved(for: traits, preference: preference)
        return chromeInset + bar.stripHeight + chromeSpacing / 2
    }

    func makeUIView(context: Context) -> KeyboardPreviewContainer {
        KeyboardPreviewContainer()
    }

    func updateUIView(_ view: KeyboardPreviewContainer, context: Context) {
        view.configure(
            preference: preference,
            showsSuggestions: showsSuggestions,
            isDark: isDark,
            showsBar: showsBar
        )
    }
}

/// Hosts the two real keyboard views and lays them out the way the extension
/// does. Touch is off: this is a picture that happens to be made of the same
/// parts, and a preview that typed into nothing would only confuse.
final class KeyboardPreviewContainer: UIView {
    private var grid: KeyGridView?
    private var bar: DictationBarView?
    private var rendered: (KeyboardHeightPreference, Bool, Bool, Bool)?

    /// Something recognisable rather than a real correction: the preview must
    /// never look like it is proposing to change text the user has not typed.
    static let sampleCandidates = [
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
        isDark: Bool,
        showsBar: Bool
    ) {
        guard rendered == nil || rendered! != (preference, showsSuggestions, isDark, showsBar) else {
            return
        }
        rendered = (preference, showsSuggestions, isDark, showsBar)

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
        bar.isHidden = !showsBar
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

#if DEBUG

// MARK: - Previews

// The height picker's whole argument is that nobody can judge 39 pt against
// 49 pt from prose. That argument applies to the picker itself: this is the
// three heights side by side, which is what the setting is choosing between.

#Preview("Keyboard preview — every height", traits: .sizeThatFitsLayout) {
    HStack(alignment: .top, spacing: 16) {
        ForEach(KeyboardHeightPreference.allCases) { preference in
            VStack(spacing: 6) {
                Text(preference.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                KeyboardPreview(preference: preference, showsSuggestions: true)
                    .frame(width: 340)
            }
        }
    }
    .padding()
}

#Preview("Keyboard preview — suggestions off", traits: .sizeThatFitsLayout) {
    KeyboardPreview(preference: .standard, showsSuggestions: false)
        .frame(width: 360)
        .padding()
}

#Preview("Keyboard preview — dark", traits: .sizeThatFitsLayout) {
    KeyboardPreview(preference: .standard, showsSuggestions: true)
        .frame(width: 360)
        .padding()
        .environment(\.colorScheme, .dark)
        .background(Color.vocaCanvas)
}
#endif
