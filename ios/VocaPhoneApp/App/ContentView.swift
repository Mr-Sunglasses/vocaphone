import SwiftUI
import UIKit

/// The home screen.
///
/// It used to be one long `List` in which the state of the session, the state of
/// Quick Dictation, the state of the gateway and a practice field all had the
/// same weight, and three of them could say "Ready" about different things at
/// once. This is a dashboard instead: what needs attention, what is happening
/// now, and where the words are going.
struct ContentView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(
        KeyboardPreferences.setupCompletedKey,
        store: KeyboardPreferences.defaults
    ) private var setupCompleted = false
    @AppStorage(
        KeyboardPreferences.firstDictationKey,
        store: KeyboardPreferences.defaults
    ) private var hasDictatedOnce = false
    @AppStorage(
        KeyboardPreferences.quickDictationKey,
        store: KeyboardPreferences.defaults
    ) private var quickDictationEnabled = true
    @AppStorage(
        KeyboardPreferences.quickDictationRecoveryOfferKey,
        store: KeyboardPreferences.defaults
    ) private var quickDictationOfferPending = false
    @State private var isShowingSourceDetail = false
    @FocusState private var diagFocused: Bool
    @Binding private var isShowingSettings: Bool
    @Binding private var isShowingQuickDictationReturnGuide: Bool

    init(
        isShowingSettings: Binding<Bool> = .constant(false),
        isShowingQuickDictationReturnGuide: Binding<Bool> = .constant(false)
    ) {
        _isShowingSettings = isShowingSettings
        _isShowingQuickDictationReturnGuide = isShowingQuickDictationReturnGuide
    }

    @State private var isShowingTranscriptionSettingsFromAttention = false
    /// The selected on-device model, observed so the attention card can react
    /// to it. `setupStatus` is a stored snapshot that home only rewrites on a
    /// return to the foreground; a download started in setup is adopted once
    /// it finishes — from the picker, or from `LocalModelManager` after a
    /// relaunch — and nothing re-read the snapshot. Home then said no model
    /// was downloaded, right under the model it had just finished.
    @AppStorage(LocalTranscriptionPreferences.modelKey, store: KeyboardPreferences.defaults)
    private var selectedModelID: String?
    #if DEBUG
    @AppStorage(AttentionCardPreview.storageKey)
    private var attentionPreviewRaw = AttentionCardPreview.off.rawValue
    #endif

    /// First-run setup is the window, not a cover over home. Opening iOS
    /// Settings used to dismiss `fullScreenCover` and flash the home screen
    /// underneath when coming back.
    private var needsFirstRunOnboarding: Bool {
        OnboardingPresentation.requiresFirstRunCover(setupCompleted: setupCompleted)
    }

    var body: some View {
        Group {
            if needsFirstRunOnboarding {
                SetupView()
            } else {
                home
            }
        }
        .task {
            coordinator.refreshSetupStatus()
            // `scenePhase` does not change on a cold launch, so the pause a
            // previous run left behind is cleared here too.
            coordinator.endQuickDictationPause()
            await coordinator.recoverRecentSession()
            coordinator.prepareQuickDictationIfEnabled()
            await coordinator.refreshGatewayHealth()
        }
        .overlay {
            if let record = keyboardHandoffRecord,
               let presentation = KeyboardHandoffPresentation.make(record)
            {
                KeyboardHandoffView(record: record, presentation: presentation)
            }
        }
    }

    private var home: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
                    attentionCard
                    modelDownloadCard
                    quickDictationOfferCard
                    sessionCard
                    sourceRow
                    transcriptCard
                }
                .padding(.horizontal, VocaMetrics.padding)
                .padding(.vertical, VocaMetrics.grouping)
            }
            .background(Color.vocaCanvas)
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
            .onChange(of: scenePhase) { previousPhase, currentPhase in
                if currentPhase == .background {
                    // The guide has done its job once the user swipes back. Do
                    // not leave it covering Home on a later ordinary launch.
                    isShowingQuickDictationReturnGuide = false
                    return
                }
                guard previousPhase != .active, currentPhase == .active else { return }
                coordinator.refreshSetupStatus()
                Task { await coordinator.refreshGatewayHealth() }
            }
            // Both halves of a model arriving: the files landing, and a model
            // being chosen for them. Either can come second.
            .onChange(of: coordinator.localModels.downloadedModelIDs) { _, _ in
                coordinator.refreshSetupStatus()
            }
            .onChange(of: selectedModelID) { _, _ in
                coordinator.refreshSetupStatus()
            }
            .navigationDestination(isPresented: $isShowingTranscriptionSettingsFromAttention) {
                TranscriptionSettingsView()
            }
            .sheet(isPresented: $isShowingSettings) {
                NavigationStack {
                    SettingsView()
                }
                .environment(coordinator)
                .tint(.brand)
            }
        }
        .overlay {
            if let record = keyboardHandoffRecord,
               let presentation = KeyboardHandoffPresentation.make(record)
            {
                KeyboardHandoffView(record: record, presentation: presentation)
            } else if isShowingQuickDictationReturnGuide {
                QuickDictationReturnGuide(reduceMotion: reduceMotion) {
                    isShowingQuickDictationReturnGuide = false
                }
            }
        }
    }

    // MARK: - Attention

    private var attentionStatus: SetupStatus {
        #if DEBUG
        if let preview = AttentionCardPreview(rawValue: attentionPreviewRaw)?.status {
            return preview
        }
        #endif
        return coordinator.setupStatus
    }

    /// A Get started in setup must not vanish when first run ends. The
    /// transfer belongs to the app, not the page that tapped it.
    private var isModelDownloadInFlight: Bool {
        coordinator.localModels.downloadingModelID != nil
            || !coordinator.localModels.queuedModelIDs.isEmpty
    }

    /// Only what actually stops dictation working reaches the top of the home
    /// screen. The truth is re-derived from the system every time rather than
    /// trusted from a one-time "setup completed" flag.
    @ViewBuilder private var attentionCard: some View {
        if let headline = attentionStatus.attentionHeadline {
            // The download card already says the model is arriving. "Download
            // a model" on top of it reads as if setup was thrown away.
            if isModelDownloadInFlight, attentionStatus.blockingSteps.first == .source {
                EmptyView()
            } else {
            VocaCard {
                VStack(alignment: .leading, spacing: VocaMetrics.padding) {
                    VocaStatusLine(
                        status: .attention,
                        title: headline,
                        detail: attentionStatus.attentionDetail
                    )
                    if let actionTitle = attentionStatus.attentionActionTitle {
                        VocaPrimaryButton(title: actionTitle) {
                            if attentionStatus.attentionOpensSystemSettings {
                                coordinator.openSystemSettings()
                            } else {
                                isShowingTranscriptionSettingsFromAttention = true
                            }
                        }
                    }
                }
            }
            }
        }
    }

    /// Same transfer the setup page showed. First run ending must not hide
    /// a model that is still coming, or home looks like setup was thrown away.
    @ViewBuilder private var modelDownloadCard: some View {
        let models = coordinator.localModels
        if let id = models.downloadingModelID ?? models.queuedModelIDs.first {
            let name = LocalModelCatalog.descriptor(for: id)?.displayName ?? "Speech model"
            let inFlight = models.downloadingModelID != nil
            VocaCard {
                VStack(alignment: .leading, spacing: VocaMetrics.padding - 2) {
                    VocaStatusLine(
                        status: .working,
                        title: inFlight ? "Downloading \(name)" : "Waiting to download \(name)",
                        detail: models.downloadTimeRemainingPhrase(for: id).map {
                            "Ready in \($0)."
                        } ?? "Started during setup. Dictation waits until this finishes."
                    )
                    if inFlight {
                        ProgressView(value: models.progress(for: id))
                            .tint(Color.brand)
                        if let size = models.downloadSizeProgress(for: id) {
                            Text(size)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Color.vocaSecondaryText)
                        }
                    }
                    NavigationLink {
                        TranscriptionSettingsView()
                    } label: {
                        Text("See models")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .accessibilityLabel(
                inFlight
                    ? "Downloading \(name), \(Int(models.progress(for: id) * 100)) percent"
                    : "Waiting to download \(name)"
            )
        }
    }

    /// Sits below the setup card, which still owns the top slot: an unfinished
    /// setup blocks dictation outright, while this only costs an app switch.
    @ViewBuilder private var quickDictationOfferCard: some View {
        if let offer = QuickDictationRecoveryOffer.make(
            isPending: quickDictationOfferPending,
            isEnabled: quickDictationEnabled
        ) {
            VocaCard {
                VStack(alignment: .leading, spacing: VocaMetrics.padding - 2) {
                    VocaStatusLine(
                        status: .inactive,
                        title: offer.title,
                        detail: offer.detail
                    )
                    // The coordinator owns both keys this card reads, and
                    // `@AppStorage` is watching the same suite, so one call
                    // turns the feature on, answers the offer, and takes the
                    // card off screen.
                    VocaPrimaryButton(title: offer.confirm, symbol: "mic.fill") {
                        coordinator.setQuickDictationEnabled(true)
                    }
                    // Taken as final. The card exists to undo a decision the
                    // user may never have made knowingly; asking twice would
                    // make it the nag it is trying not to be.
                    Button(offer.dismiss) {
                        quickDictationOfferPending = false
                    }
                    .frame(maxWidth: .infinity)
                    .font(.subheadline)
                }
            }
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
                quickDictationDuration: coordinator.quickDictationDuration,
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
                                : "Nothing yet. Tap Dictate in the keyboard from any app."
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

    private var keyboardHandoffRecord: SessionRecord? {
        guard let record = coordinator.activeRecord,
              KeyboardHandoffPresentation.shouldPresent(record)
        else { return nil }
        return record
    }
}

/// The keyboard may open the app from a cold start. Do not tell the user to
/// return until the recorder has actually taken standby and published the
/// availability lease the keyboard consumes.
private struct QuickDictationReturnGuide: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    let reduceMotion: Bool
    let onDismiss: () -> Void
    /// Arming takes well under a second when it works. A wait past this is
    /// not going to end on its own — audio held by a call, another app's
    /// session — so the screen stops asking for patience and offers a way out
    /// instead of covering Home until the user leaves the app.
    @State private var isTakingLong = false

    var body: some View {
        if coordinator.isQuickDictationReady {
            SwipeBackScreen(
                title: "Swipe back to your keyboard",
                detail: "Quick Dictation is ready. Tap the microphone there.",
                reduceMotion: reduceMotion
            )
        } else if coordinator.setupStatus.microphone == .denied {
            status(
                title: "Microphone access is off",
                detail: "Quick Dictation needs the microphone. Turn it on in Settings, then try again."
            ) {
                VocaPrimaryButton(title: "Open Settings", symbol: "gear") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        } else {
            status(
                title: "Getting Quick Dictation ready",
                detail: isTakingLong
                    ? (coordinator.message ?? "VocaPhone could not get the microphone yet.")
                    : "Keep VocaPhone open for a moment.",
                showsProgress: true
            ) {
                EmptyView()
            }
            .task {
                try? await Task.sleep(for: .seconds(4))
                isTakingLong = true
            }
        }
    }

    private func status<Actions: View>(
        title: String,
        detail: String,
        showsProgress: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        ZStack {
            Color.vocaCanvas.ignoresSafeArea()
            VStack(spacing: VocaMetrics.grouping) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.brand)
                }
                Text(title)
                    .font(.title2.weight(.bold))
                Text(detail)
                    .font(.body)
                    .foregroundStyle(Color.vocaSecondaryText)
                actions()
                if !showsProgress || isTakingLong {
                    Button("Close", action: onDismiss)
                        .font(.body.weight(.semibold))
                        .frame(minHeight: VocaMetrics.minimumTarget)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
            .padding(VocaMetrics.grouping)
        }
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

#if DEBUG

// MARK: - Previews

// Every state `HomeSessionCard.make` can produce, plus the two overlays the
// home screen owns. These are the states the visual QA matrix asks for and the
// ones nobody could reach without a gateway to break and a permission to
// decline.

#Preview("Home — ready to dictate") {
    PreviewHost(coordinator: .previewIdle()) { ContentView() }
}

#Preview("Home — first run, nothing set up") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupFresh
        ),
        hasDictatedOnce: false
    ) { ContentView() }
}

#Preview("Home — two steps outstanding") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupTwoStepsLeft
        )
    ) { ContentView() }
}

#Preview("Home — no model downloaded") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: SetupStatus(
                source: PreviewFixtures.onDeviceMissing,
                microphone: .granted,
                keyboard: .ready(lastSeenAt: Date()),
                hasDictatedOnce: true
            )
        )
    ) { ContentView() }
}

#Preview("Home — Quick Dictation standby") {
    PreviewHost(coordinator: .previewStandby()) { ContentView() }
}

#Preview("Home — starting the microphone") {
    PreviewHost(coordinator: .preview(.launchingApp, startedInApp: false)) { ContentView() }
}

#Preview("Home — listening") {
    PreviewHost(
        coordinator: .preview(.recording, meterLevel: 0.62, isRecording: true)
    ) { ContentView() }
}

#Preview("Home — transcribing on the gateway") {
    PreviewHost(coordinator: .preview(.transcribing)) { ContentView() }
}

#Preview("Home — transcribing on this iPhone") {
    PreviewHost(
        coordinator: .preview(
            .transcribing,
            processingLocation: .onDevice,
            setupStatus: SetupStatus(
                source: PreviewFixtures.onDeviceReady,
                microphone: .granted,
                keyboard: .ready(lastSeenAt: Date()),
                hasDictatedOnce: true
            )
        )
    ) { ContentView() }
}

#Preview("Home — transcript ready, long") {
    PreviewHost(
        coordinator: .preview(.completed, transcript: PreviewFixtures.longTranscript)
    ) { ContentView() }
}

#Preview("Home — inserted into another app") {
    PreviewHost(
        coordinator: .preview(
            .completed,
            transcript: PreviewFixtures.shortTranscript,
            startedInApp: false
        )
    ) { ContentView() }
}

#Preview("Home — gateway unavailable, audio kept") {
    PreviewHost(
        coordinator: .preview(
            .serverUnavailable,
            error: PreviewFixtures.gatewayFailure,
            message: PreviewFixtures.gatewayFailure.message
        )
    ) { ContentView() }
}

#Preview("Home — microphone access denied") {
    PreviewHost(
        coordinator: .preview(
            .permissionDenied,
            error: PreviewFixtures.permanentFailure,
            setupStatus: PreviewFixtures.setupMicrophoneDenied,
            message: "vocaphone cannot record without microphone access."
        )
    ) { ContentView() }
}

#Preview("Home — transcription failed for good") {
    PreviewHost(
        coordinator: .preview(
            .transcriptionFailedPermanent,
            error: PreviewFixtures.permanentFailure,
            message: PreviewFixtures.permanentFailure.message
        )
    ) { ContentView() }
}

/// The hand-off overlay, which only appears for a dictation started from
/// another app — the one home state that covers the whole screen.
#Preview("Return guide — keyboard is recording") {
    PreviewHost(
        coordinator: .preview(
            .recording,
            startedInApp: false,
            meterLevel: 0.48,
            isRecording: true
        )
    ) { ContentView() }
}

#Preview("Home — matrix", traits: .sizeThatFitsLayout) {
    PreviewMatrix(coordinator: .preview(.serverUnavailable, error: PreviewFixtures.gatewayFailure)) {
        ContentView()
    }
}

#Preview("Meter — quiet, speaking, loud", traits: .sizeThatFitsLayout) {
    VStack(spacing: VocaMetrics.grouping) {
        ForEach([Float(0.05), 0.35, 0.85], id: \.self) { level in
            PreviewHost(coordinator: .preview(.recording, meterLevel: level, isRecording: true)) {
                RecordingMeter()
                    .frame(width: 280)
                    .padding()
            }
        }
    }
    .padding()
}
#endif
