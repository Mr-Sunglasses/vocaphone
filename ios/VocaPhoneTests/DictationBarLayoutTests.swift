import Testing
import UIKit

@MainActor
struct DictationBarLayoutTests {
    private static let referenceWidth: CGFloat = 393 - 12

    private static func makeBar(
        _ model: DictationBarModel,
        traits: UITraitCollection = UITraitCollection { $0.verticalSizeClass = .regular },
        isDark: Bool = false
    ) -> DictationBarView {
        let metrics = DictationBarMetrics.resolved(for: traits)
        let bar = DictationBarView(metrics: metrics, palette: KeyboardPalette(isDark: isDark))
        bar.frame = CGRect(
            x: 0,
            y: 0,
            width: referenceWidth,
            height: metrics.height(expanded: model.isExpanded)
        )
        bar.apply(model, animated: false)
        bar.layoutIfNeeded()
        return bar
    }

    private static func model(_ state: SessionState, transcript: String? = nil) -> DictationBarModel {
        DictationBarModel.make(DictationContext(state: state, transcript: transcript))
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    /// Anything that is drawing has to be inside the bar. The previous card left
    /// its subtitle and meter to be clipped whenever the status text grew.
    @Test func nothingVisibleEscapesTheBar() {
        for state in SessionState.allCases {
            let bar = Self.makeBar(Self.model(state, transcript: String(repeating: "long ", count: 40)))
            for view in Self.descendants(of: bar) where !view.isHidden && view.alpha > 0 {
                let frame = view.convert(view.bounds, to: bar)
                guard frame.width > 0, frame.height > 0 else { continue }
                #expect(frame.minX >= -0.5)
                #expect(frame.maxX <= bar.bounds.width + 0.5)
            }
        }
    }

    /// The headline and the body share the space the action buttons leave, so a
    /// long title must never end up drawn underneath the primary button.
    @Test func theActionButtonsKeepTheirColumnClear() {
        let bar = Self.makeBar(Self.model(.recording))
        let primary = Self.descendants(of: bar).first { $0 is GradientButton }
        let waveform = Self.descendants(of: bar).first { $0 is WaveformView }
        #expect(primary != nil)
        #expect(waveform != nil)
        guard let primary, let waveform else { return }
        let primaryFrame = primary.convert(primary.bounds, to: bar)
        let waveformFrame = waveform.convert(waveform.bounds, to: bar)
        #expect(waveformFrame.maxX <= primaryFrame.minX)
        #expect(primaryFrame.maxX <= bar.bounds.width)
        #expect(waveformFrame.width > 0)
    }

    /// The body views all stay in place at zero alpha so a state change
    /// dissolves instead of re-laying out — which means only the one the model
    /// asked for may be on screen.
    @Test func onlyTheModelsOwnBodyViewIsVisible() {
        let bar = Self.makeBar(Self.model(.idle))
        let waveforms = Self.descendants(of: bar).compactMap { $0 as? WaveformView }
        #expect(waveforms.count == 1)

        for state in SessionState.allCases {
            let model = Self.model(state)
            bar.apply(model, animated: false)
            bar.layoutIfNeeded()
            let showsMeter = waveforms.contains { !$0.isHidden && $0.alpha > 0 }
            let wantsMeter = switch model.body {
            case .waveform: true
            case .controls, .message: false
            }
            #expect(showsMeter == wantsMeter)
        }
    }

    @Test func theBarSurvivesRepeatedRendersOfTheSameState() {
        let bar = Self.makeBar(Self.model(.recording))
        let before = Self.descendants(of: bar).count
        for _ in 0..<20 {
            bar.apply(Self.model(.recording), animated: false)
            bar.push(meterLevel: 0.6)
        }
        bar.layoutIfNeeded()
        // A poll tick that changes nothing must not accumulate views.
        #expect(Self.descendants(of: bar).count == before)
    }

    @Test func bothAppearancesResolveEveryAccent() {
        for isDark in [true, false] {
            let palette = KeyboardPalette(isDark: isDark)
            let accents: [DictationAccent] = [
                .brand, .handoff, .listening, .working, .ready, .alert, .locked,
            ]
            for accent in accents {
                #expect(palette.gradient(for: accent).count == 2)
                #expect(palette.tint(for: accent) == palette.gradient(for: accent)[0])
            }
        }
    }
}
