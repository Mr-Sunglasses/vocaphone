import SwiftUI
import UIKit

/// The home screen.
///
/// It used to be one long `List` in which the state of the session, the state of
/// Quick Dictation, the state of the gateway and a practice field all had the
/// same weight, and three of them could say "Ready" about different things at
/// once. This is a dashboard instead: what needs attention, what is happening
/// now, somewhere to try it, and where the words are going.
struct ContentView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(
        KeyboardPreferences.setupCompletedKey,
        store: KeyboardPreferences.defaults
    ) private var setupCompleted = false
    /// Deliberately not derived from `setupCompleted`: the cover opens once per
    /// install, and leaving setup must not reopen it.
    @State private var isShowingSetup = false
    @AppStorage(
        KeyboardPreferences.firstDictationKey,
        store: KeyboardPreferences.defaults
    ) private var hasDictatedOnce = false
    @State private var testText = ""
    @State private var isShowingSourceDetail = false
    @FocusState private var diagFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
                    attentionCard
                    sessionCard
                    practiceCard
                    sourceRow
                    transcriptCard
                }
                .padding(.horizontal, VocaMetrics.padding)
                .padding(.vertical, VocaMetrics.grouping)
            }
            .background(Color.vocaCanvas)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("vocaphone")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BrandMark(size: 24)
                        .accessibilityHidden(true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .task {
                if !setupCompleted { isShowingSetup = true }
                coordinator.refreshSetupStatus()
                await coordinator.recoverRecentSession()
                coordinator.prepareQuickDictationIfEnabled()
                await coordinator.refreshGatewayHealth()
            }
            .onChange(of: scenePhase) { previousPhase, currentPhase in
                guard previousPhase != .active, currentPhase == .active else { return }
                coordinator.refreshSetupStatus()
                Task { await coordinator.refreshGatewayHealth() }
            }
            .fullScreenCover(isPresented: $isShowingSetup) {
                NavigationStack {
                    SetupView()
                }
            }
        }
        .overlay {
            if showsKeyboardReturnGuide {
                KeyboardReturnGuide(
                    startedAt: coordinator.activeRecord?.createdAt ?? Date(),
                    finish: coordinator.requestFinish,
                    cancel: coordinator.cancel
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsKeyboardReturnGuide)
    }

    // MARK: - Attention

    /// Only what actually stops dictation working reaches the top of the home
    /// screen; the rest of the checklist stays behind guided setup. The truth is
    /// re-derived from the system every time rather than trusted from a
    /// one-time "setup completed" flag.
    @ViewBuilder private var attentionCard: some View {
        if let headline = coordinator.setupStatus.attentionHeadline {
            NavigationLink {
                SetupView()
            } label: {
                VocaCard {
                    VStack(alignment: .leading, spacing: VocaMetrics.related + 4) {
                        VocaStatusLine(
                            status: .attention,
                            title: headline,
                            detail: coordinator.setupStatus.attentionDetail
                        )
                        Label("Finish setup", systemImage: "arrow.forward")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.brand)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Session

    private var card: HomeSessionCard {
        HomeSessionCard.make(
            HomeSessionCard.Context(
                state: coordinator.activeRecord?.state ?? .idle,
                isRecording: coordinator.isRecording,
                isQuickDictationReady: coordinator.isQuickDictationReady,
                quickDictationExpiresAt: coordinator.quickDictationExpiresAt,
                processingLocation: coordinator.activeRecord?.processingLocation,
                transcript: coordinator.transcript,
                errorMessage: coordinator.hasError ? coordinator.message : nil,
                canRetry: coordinator.activeRecord?.canRetry == true,
                // Read from the record, not from `isKeyboardRecording`: that one
                // is false once capture stops, which would let a transcript
                // dictated from another app offer itself for copying here as
                // though this screen owned it.
                startedInApp: coordinator.activeRecord.map(Self.startedInApp) ?? true,
                isSourceReady: coordinator.setupStatus.source.isReady
            )
        )
    }

    /// Whether this dictation belongs to vocaphone's own field. A microphone
    /// test and the practice field both do; a session started from the keyboard
    /// in another app does not, and its transcript is delivered there.
    private static func startedInApp(_ record: SessionRecord) -> Bool {
        record.sourceDocumentID == "in-app-test" || record.startedInContainingApp == true
    }

    private var sessionCard: some View {
        let model = card
        return VocaCard(padding: VocaMetrics.grouping) {
            VStack(alignment: .leading, spacing: VocaMetrics.padding - 2) {
                VocaStatusLine(
                    status: model.status,
                    title: model.title,
                    detail: model.detail,
                    // The one card on this screen the eye should land on. The
                    // others were all the same weight, so it had nowhere to land.
                    isProminent: true
                )

                if model.showsMeter {
                    RecordingMeter()
                }

                if model.showsTranscript, let transcript = coordinator.transcript {
                    Text(transcript)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(VocaMetrics.related + 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.vocaRecessedSurface,
                            in: RoundedRectangle(
                                cornerRadius: VocaMetrics.fieldRadius,
                                style: .continuous
                            )
                        )
                }

                if let primary = model.primary {
                    if primary.action == .copyTranscript {
                        VocaCopyButton(title: primary.title, value: coordinator.transcript)
                    } else {
                        VocaPrimaryButton(title: primary.title, symbol: primary.symbol) {
                            perform(primary.action)
                        }
                        .disabled(isDisabled(primary.action))
                    }
                }
                if let secondary = model.secondary {
                    Button(secondary.title, role: .destructive) { perform(secondary.action) }
                        .frame(maxWidth: .infinity)
                        .font(.subheadline)
                }
            }
        }
    }

    private func isDisabled(_ action: HomeSessionAction) -> Bool {
        action == .startTest && !coordinator.setupStatus.source.isReady
    }

    private func perform(_ action: HomeSessionAction) {
        switch action {
        case .startTest:
            coordinator.startInAppTest()
        case .finish:
            coordinator.requestFinish()
        case .cancel:
            coordinator.cancel()
        case .retry:
            coordinator.retryPreservedRecording()
        case .copyTranscript:
            UIPasteboard.general.string = coordinator.transcript
        }
    }

    // MARK: - Practice

    /// A real field, not a screenshot. Dictating into it is the whole loop —
    /// switch keyboard, speak, watch the text arrive — with no app switch in the
    /// middle, which makes it the shortest honest demonstration of the product.
    private var practiceCard: some View {
        VocaCard {
            VStack(alignment: .leading, spacing: VocaMetrics.related + 4) {
                VocaSectionHeader(title: "Try the keyboard")

                TextField("Type or dictate here", text: $testText, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($diagFocused)
                    .task {
                        guard ProcessInfo.processInfo.arguments.contains("-diagFocusField")
                        else { return }
                        try? await Task.sleep(for: .milliseconds(600))
                        diagFocused = true
                    }
                    .textFieldStyle(.plain)
                    .padding(VocaMetrics.related + 4)
                    .background(
                        Color.vocaRecessedSurface,
                        in: RoundedRectangle(
                            cornerRadius: VocaMetrics.fieldRadius,
                            style: .continuous
                        )
                    )

                if coordinator.isDictatingIntoContainingApp {
                    // Dictating into this field needs no app switch, so the
                    // controls are inline rather than behind a hand-off screen.
                    HStack(spacing: VocaMetrics.related + 2) {
                        Image(systemName: "record.circle")
                            .foregroundStyle(Color.vocaRecording)
                            .accessibilityHidden(true)
                        Text("Listening")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        RecordingMeter()
                            .frame(width: 90)
                    }
                    .accessibilityElement(children: .combine)

                    VocaPrimaryButton(title: "Finish recording", symbol: "stop.fill") {
                        coordinator.requestFinish()
                    }
                    Button("Cancel", role: .destructive) { coordinator.cancel() }
                        .frame(maxWidth: .infinity)
                        .font(.subheadline)
                    Text("The transcript drops straight into the field above.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !hasDictatedOnce {
                    // Three sentences of setup text, retired once the user has
                    // proved they no longer need them. A permanent instruction
                    // is an instruction nobody reads.
                    Text(
                        "Tap the field, hold 🌐 and choose vocaphone, then tap Dictate. "
                            + "From another app the keyboard opens vocaphone to record — "
                            + "swipe back once it starts, then tap Finish."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Processing source

    /// One row, not a card.
    ///
    /// Which route is selected matters at setup time and after a failure. The
    /// rest of the time it is a fact about the app, not a task — and a permanent
    /// card for it competed with the session for attention it did not need.
    private var sourceRow: some View {
        let source = coordinator.setupStatus.source
        return VocaCard {
            VStack(alignment: .leading, spacing: VocaMetrics.related + 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingSourceDetail.toggle()
                    }
                } label: {
                    HStack(spacing: VocaMetrics.related) {
                        Image(systemName: source.symbolName)
                            .foregroundStyle(source.isReady ? Color.brand : Color.vocaWarning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Speech to text")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(source.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                        Image(systemName: isShowingSourceDetail ? "chevron.up" : "chevron.down")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Speech to text: \(source.title)")
                .accessibilityHint(isShowingSourceDetail ? "Hides the details." : "Shows the details.")

                if isShowingSourceDetail || !source.isReady {
                    VStack(alignment: .leading, spacing: VocaMetrics.related) {
                        Text(source.readinessDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(source.boundaryDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        NavigationLink {
                            TranscriptionSettingsView()
                        } label: {
                            Label(
                                source.isReady
                                    ? "Change transcription source"
                                    : source.recoveryActionTitle,
                                systemImage: "arrow.forward"
                            )
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Transcripts

    /// Two cards showing the same words is the bug the dashboard rewrite was
    /// meant to remove, so this one stands down whenever the session card is
    /// already showing the latest transcript.
    @ViewBuilder private var transcriptCard: some View {
        if !card.showsTranscript {
            VocaCard {
                VStack(alignment: .leading, spacing: VocaMetrics.related + 4) {
                    VocaSectionHeader(title: "Latest transcript")
                    if let transcript = coordinator.transcript, !transcript.isEmpty {
                        Text(transcript)
                            .font(.body)
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(
                            hasDictatedOnce
                                ? "Dictations you finish will appear here."
                                : "Nothing yet. Try the field above, or tap Dictate in "
                                    + "the keyboard from any app."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    NavigationLink {
                        TranscriptHistoryView()
                    } label: {
                        Label("All transcripts", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    private var showsKeyboardReturnGuide: Bool {
        if coordinator.isKeyboardRecording { return true }
#if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-previewKeyboardReturnGuide")
#else
        return false
#endif
    }
}

struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        Image("BrandMark")
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(Color.brand)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

/// The level updates several times a second. Keeping it in a leaf view means
/// only this redraws, instead of every screen observing the coordinator.
struct RecordingMeter: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bars, not a progress bar. A `ProgressView` says "this is N per cent
    /// finished", which is exactly what a voice level is not — and at a glance
    /// a half-full bar reads as a half-finished recording.
    private static let barCount = 18

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let width = max(
                2,
                (proxy.size.width - spacing * CGFloat(Self.barCount - 1)) / CGFloat(Self.barCount)
            )
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(fill(for: index))
                        .frame(width: width, height: height(for: index, in: proxy.size.height))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(
                reduceMotion ? nil : .linear(duration: 0.1),
                value: coordinator.meterLevel
            )
        }
        .frame(height: 26)
        .accessibilityElement()
        .accessibilityLabel("Voice level")
        .accessibilityValue("\(Int(coordinator.meterLevel * 100)) percent")
    }

    private func height(for index: Int, in available: CGFloat) -> CGFloat {
        let level = CGFloat(coordinator.meterLevel)
        let position = CGFloat(index) / CGFloat(Self.barCount - 1)
        // A gentle arc, tallest in the middle, so the meter reads as a voice
        // rather than as a bar chart.
        let shape = 0.45 + 0.55 * sin(position * .pi)
        return max(3, available * min(1, level * shape * 1.6))
    }

    private func fill(for index: Int) -> Color {
        let level = CGFloat(coordinator.meterLevel)
        let position = CGFloat(index) / CGFloat(Self.barCount - 1)
        return Color.vocaRecording.opacity(level * (0.45 + 0.55 * sin(position * .pi)) > 0.06 ? 1 : 0.22)
    }
}

private struct RecordingPulse: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var level: CGFloat {
        coordinator.isKeyboardRecording ? CGFloat(coordinator.meterLevel) : 0.42
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.vocaRecording.opacity(0.12))
                .frame(width: 108, height: 108)
            Circle()
                .fill(Color.vocaRecording)
                .frame(width: 58 + responsiveLevel * 18, height: 58 + responsiveLevel * 18)
                .animation(.linear(duration: 0.12), value: responsiveLevel)
            Image(systemName: "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    /// Reduce Motion stops the size following the microphone; the state stays
    /// perfectly visible without it, which is the test the setting asks for.
    private var responsiveLevel: CGFloat { reduceMotion ? 0.42 : level }
}

/// Shown while the keyboard is recording, to say the one thing that is not
/// obvious: go back to where you were typing.
///
/// It used to draw a fake home bar with an arrow animating across it forever.
/// The drawing was a picture of a gesture rather than the gesture, the loop ran
/// for the whole recording, and between them they made a routine hand-off feel
/// like an alert. What is left is the live state — a pulse that follows the
/// input level, and a timer — plus one sentence of instruction.
private struct KeyboardReturnGuide: View {
    let startedAt: Date
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.vocaCanvas
                .ignoresSafeArea()

            VStack(spacing: VocaMetrics.grouping + 4) {
                Spacer()

                RecordingPulse()

                VStack(spacing: VocaMetrics.related) {
                    Text("vocaphone is listening")
                        .font(.title2.weight(.semibold))
                    Text(startedAt, style: .timer)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: VocaMetrics.related - 2) {
                    Text("Swipe right across the bottom edge to go back")
                        .font(.headline)
                    Text(
                        "Recording continues in the background. When the keyboard "
                            + "reappears, tap Finish — or use Finish in the Dynamic Island."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                Spacer()

                VStack(spacing: VocaMetrics.related) {
                    VocaPrimaryButton(title: "Finish recording here instead", action: finish)
                    Button("Cancel recording", role: .destructive, action: cancel)
                        .font(.subheadline)
                }
            }
            .padding(VocaMetrics.grouping + 4)
        }
    }
}
