#if DEBUG
import SwiftUI
import UIKit

/// The keyboard's own views, in any session state, without the extension.
///
/// Looking at a dictation state normally costs a device build, adding the
/// keyboard in iOS Settings, opening a host app, and actually speaking — for
/// every one-point change to a bar nobody can see from the app. These are the
/// same `DictationBarView` and `KeyGridView` the extension builds, driven by a
/// state picker and a synthetic meter, so a state can be looked at in the
/// simulator in a second.
///
/// Debug only, and unreachable from a release build: `just ios lint-previews`
/// fails if anything here becomes reachable from one.
struct KeyboardLabView: View {
    @State private var state: SessionState = .recording
    @State private var isDark = false
    @State private var isSpeaking = true
    @State private var showsCandidates = false
    @State private var usesSurface = true
    @State private var hapticStyle = KeyboardPreferences.typingHapticStyle
    @State private var hapticIntensity = KeyboardPreferences.typingHapticIntensity
    @State private var keyReleaseFade = KeyboardPreferences.keyReleaseFade
    @State private var keyPreviewAnimates = KeyboardPreferences.keyPreviewAnimates
    @StateObject private var surface = DictationSurfaceState()
    /// Synthetic levels at the rate the microphone produces them: five per
    /// quarter-second tick, the same split `AudioCapturePipeline` makes.
    private let meterTick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    /// Every state worth looking at, in the order a session moves through them,
    /// failures last. The point of the lab is the states nobody can reach on
    /// purpose — an unreachable gateway, a transcript that came back empty, a
    /// field that went away while the app was open.
    private static let states: [SessionState] = [
        .idle,
        .launchingApp,
        .recording,
        .transcribing,
        .readyToInsert,
        .targetContextChanged,
        .serverUnavailable,
        .uploadFailedRecoverable,
        .transcriptionFailedRecoverable,
        .transcriptionFailedPermanent,
        .permissionDenied,
    ]

    /// What the keyboard is on a phone: strip, gap, grid, insets. The preview
    /// holds this height in every state, because the keyboard does — a preview
    /// that collapses is showing a bug it invented itself.
    private static let keyboardHeight: CGFloat = 274

    private static let sampleCandidates: [TypingCandidate] = [
        TypingCandidate(text: "whats", kind: .literal),
        TypingCandidate(text: "what's", kind: .correction, isEmphasised: true),
        TypingCandidate(text: "whatsapp", kind: .completion),
    ]

    var body: some View {
        List {
            Section {
                if usesSurface {
                    DictationSurfaceView(state: surface)
                        .padding(.horizontal, 12)
                        .frame(height: Self.keyboardHeight, alignment: .top)
                        .background(
                            (isDark ? Color(white: 0.09) : Color(white: 0.886))
                                .clipShape(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                )
                        )
                        .environment(\.colorScheme, isDark ? .dark : .light)
                } else {
                    KeyboardLabRepresentable(
                        state: state,
                        isDark: isDark,
                        isSpeaking: isSpeaking
                    )
                    .frame(height: 340)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            Section {
                Toggle("New surface", isOn: $usesSurface)
                Picker("State", selection: $state) {
                    ForEach(Self.states, id: \.self) { state in
                        Text(state.displayName).tag(state)
                    }
                }
                Toggle("Dark keyboard", isOn: $isDark)
                Toggle("Speaking", isOn: $isSpeaking)
                Toggle("Suggestions", isOn: $showsCandidates)
            } footer: {
                Text("Tap the microphone in the preview to play the transition.")
            }
            transitionSection
            hapticsSection
        }
        .navigationTitle("Keyboard lab")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            surface.animationResponse = KeyboardPreferences.surfaceAnimationResponse
            surface.animationDamping = KeyboardPreferences.surfaceAnimationDamping
            syncSurface()
        }
        .onChange(of: state) { syncSurface() }
        .onChange(of: isDark) { syncSurface() }
        .onChange(of: showsCandidates) { syncSurface() }
        .onReceive(meterTick) { _ in
            guard usesSurface, state == .recording, isSpeaking else { return }
            surface.appendMeterLevels(Self.nextLevels())
        }
    }

    /// Two sliders, because a spring is judged by thumb and not by argument.
    private var transitionSection: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Response \(surface.animationResponse, specifier: "%.2f") s")
                    .font(.footnote.monospacedDigit())
                Slider(value: $surface.animationResponse, in: 0.05...0.60)
            }
            VStack(alignment: .leading) {
                Text("Damping \(surface.animationDamping, specifier: "%.2f")")
                    .font(.footnote.monospacedDigit())
                Slider(value: $surface.animationDamping, in: 0.5...1.0)
            }
            Button("Reset to shipped values") {
                surface.animationResponse = 0.15
                surface.animationDamping = 1.0
            }
        } header: {
            Text("Transition")
        } footer: {
            Text(
                "Response is how long the change takes; damping is how much it "
                    + "overshoots — 1.00 does not overshoot at all. Tell me the "
                    + "pair you settle on and it goes into the keyboard."
            )
        }
    }

    /// The key tap, tuned by hand. Fires on every change so the thumb hears
    /// the answer while the slider is still under it.
    private var hapticsSection: some View {
        Section {
            Picker("Feel", selection: $hapticStyle) {
                ForEach(TypingHapticStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Text(hapticStyle.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text("Strength \(hapticIntensity, specifier: "%.2f")")
                    .font(.footnote.monospacedDigit())
                Slider(value: $hapticIntensity, in: 0.2...1.0)
            }
            Button("Play it") { playHaptic() }
            Toggle("Release fade on letters", isOn: $keyReleaseFade)
            Toggle("Animate the key preview", isOn: $keyPreviewAnimates)
        } header: {
            Text("Key press")
        } footer: {
            Text(
                "This is the tap a letter gives back. It needs Full Access on "
                    + "the keyboard itself; here in the app it always plays."
            )
        }
        .onChange(of: hapticStyle) {
            KeyboardPreferences.typingHapticStyle = hapticStyle
            playHaptic()
        }
        .onChange(of: hapticIntensity) {
            KeyboardPreferences.typingHapticIntensity = hapticIntensity
        }
        .onChange(of: keyReleaseFade) {
            KeyboardPreferences.keyReleaseFade = keyReleaseFade
        }
        .onChange(of: keyPreviewAnimates) {
            KeyboardPreferences.keyPreviewAnimates = keyPreviewAnimates
        }
    }

    private func playHaptic() {
        let generator = UIImpactFeedbackGenerator(style: hapticStyle.feedbackStyle)
        generator.prepare()
        generator.impactOccurred(intensity: hapticIntensity)
    }

    private func syncSurface() {
        surface.state = state
        surface.isDark = isDark
        surface.showsGlobeKey = true
        surface.candidates = showsCandidates && state == .idle ? Self.sampleCandidates : []
        if state != .recording { surface.clearMeterLevels() }

        // The same model the extension draws from, so the copy in the lab is
        // the copy on the phone rather than something written for the preview.
        let model = DictationBarModel.make(
            DictationContext(
                state: state,
                transcript: state == .readyToInsert ? "This is what came back." : nil,
                errorMessage: nil,
                canRetry: true
            )
        )
        surface.primarySymbol = model.primary.symbol
        surface.primaryIsEnabled = model.primary.isEnabled
        surface.centerMessage = model.surfaceMessage(for: state)
        // The lab stands in for the session the extension would be driving.
        // Without these the buttons are a picture of buttons: they call a
        // closure nobody set, and nothing happens when you press them.
        surface.onStart = { state = .recording }
        surface.onFinish = { state = .transcribing }
        surface.onCancel = { state = .idle }
    }

    /// Syllables over a slower breath. A sine wave reads as a machine humming.
    private static var meterPhase: CGFloat = 0

    private static func nextLevels() -> [Float] {
        (0..<5).map { _ in
            meterPhase += 0.28
            let syllable = abs(sin(meterPhase * 2.3))
            let breath = 0.45 + 0.45 * abs(sin(meterPhase * 0.21))
            return Float(min(max(syllable * breath, 0.05), 1))
        }
    }
}

private struct KeyboardLabRepresentable: UIViewRepresentable {
    let state: SessionState
    let isDark: Bool
    let isSpeaking: Bool

    func makeUIView(context: Context) -> KeyboardLabContainer {
        KeyboardLabContainer()
    }

    func updateUIView(_ view: KeyboardLabContainer, context: Context) {
        view.configure(state: state, isDark: isDark, isSpeaking: isSpeaking)
    }
}

/// Lays the two keyboard views out the way `KeyboardViewController` does:
/// hung from the bottom, one chrome inset around them.
final class KeyboardLabContainer: UIView {
    private var grid: KeyGridView?
    private var bar: DictationBarView?
    private var barLayout: DictationBarLayout = .strip
    private var isExpanded = false
    private var meterTimer: Timer?
    private var meterPhase: CGFloat = 0

    private static let chromeInset: CGFloat = 6
    private static let chromeSpacing: CGFloat = 12
    /// Matches `AudioCapturePipeline.meterSlices` over one quarter-second tick,
    /// so the meter is fed at the rate the microphone actually feeds it.
    private static let meterTick: TimeInterval = 0.25
    private static let levelsPerTick = 5

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(state: SessionState, isDark: Bool, isSpeaking: Bool) {
        let traits = UITraitCollection { $0.verticalSizeClass = .regular }
        let palette = KeyboardPalette(isDark: isDark)
        let gridMetrics = KeyboardMetrics.resolved(for: traits, preference: .standard)
        let barMetrics = DictationBarMetrics.resolved(for: traits, preference: .standard)
        // The extension leaves this to the system's input view. Here there is
        // no input view, so the fallback colour stands in for it.
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

        let bar = self.bar ?? {
            let created = DictationBarView(metrics: barMetrics, palette: palette)
            addSubview(created)
            self.bar = created
            return created
        }()
        bar.metrics = barMetrics
        bar.palette = palette

        let model = DictationBarModel.make(
            DictationContext(
                state: state,
                transcript: state == .readyToInsert ? "This is what came back." : nil,
                errorMessage: state == .serverUnavailable ? "Gateway unavailable" : nil
            )
        )
        barLayout = model.layout
        isExpanded = model.isExpanded
        bar.apply(model, animated: false)

        if state == .recording, isSpeaking {
            startMeter(on: bar)
        } else {
            stopMeter()
        }
        setNeedsLayout()
    }

    private func startMeter(on bar: DictationBarView) {
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(
            withTimeInterval: Self.meterTick,
            repeats: true
        ) { [weak self, weak bar] _ in
            MainActor.assumeIsolated {
                guard let self, let bar else { return }
                bar.push(meterLevels: self.nextLevels())
            }
        }
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    /// Something with the shape of speech: syllables on top of a slower breath,
    /// rather than a sine wave, which reads as a machine humming.
    private func nextLevels() -> [Float] {
        (0..<Self.levelsPerTick).map { _ in
            meterPhase += 0.28
            let syllable = abs(sin(meterPhase * 2.3))
            let breath = 0.45 + 0.45 * abs(sin(meterPhase * 0.21))
            return Float(min(max(syllable * breath, 0.05), 1))
        }
    }

    /// The timer retains this view through its own block, so the meter has to
    /// stop when the view leaves the screen; a `deinit` would never run.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopMeter() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let grid, let bar else { return }
        let traits = UITraitCollection { $0.verticalSizeClass = .regular }
        let gridMetrics = KeyboardMetrics.resolved(for: traits, preference: .standard)
        let barMetrics = DictationBarMetrics.resolved(for: traits, preference: .standard)
        let inset = Self.chromeInset
        let width = bounds.width - 2 * inset
        let barHeight = barMetrics.height(for: barLayout, expanded: isExpanded)
        let gridTop = bounds.height - gridMetrics.gridHeight
        grid.frame = CGRect(
            x: inset,
            y: gridTop,
            width: width,
            height: gridMetrics.gridHeight
        )
        bar.frame = CGRect(
            x: inset,
            y: max(inset, gridTop - Self.chromeSpacing - barHeight),
            width: width,
            height: barHeight
        )
    }
}
#endif
