import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(
        KeyboardPreferences.quickDictationKey,
        store: KeyboardPreferences.defaults
    ) private var quickDictationEnabled = true
    @AppStorage(
        KeyboardPreferences.setupCompletedKey,
        store: KeyboardPreferences.defaults
    ) private var setupCompleted = false
    /// Deliberately not derived from `setupCompleted`: the cover opens once per
    /// install, and leaving setup must not reopen it.
    @State private var isShowingSetup = false
    @State private var testText = ""

    var body: some View {
        NavigationStack {
            List {
                setupBanner
                sessionSection
                transcriptSection
                practiceSection
            }
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

    // MARK: - Setup

    /// Only what actually stops dictation working earns a place at the top of
    /// the main screen; the rest of the checklist stays behind guided setup.
    ///
    /// The row carries no "Finish setup" line of its own: it is a
    /// `NavigationLink`, so the chevron already says where tapping goes.
    @ViewBuilder private var setupBanner: some View {
        if let headline = coordinator.setupStatus.attentionHeadline {
            Section {
                NavigationLink {
                    SetupView()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(headline)
                            if let detail = coordinator.setupStatus.attentionDetail {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Sections

    /// The explanations live in the section footer rather than in rows of their
    /// own. A paragraph in a `List` row gets a cell and two separators, which is
    /// what made this screen read as a stack of unrelated slabs.
    private var sessionSection: some View {
        Section {
            LabeledContent("State", value: coordinator.stateLabel)

            if coordinator.isRecording {
                RecordingMeter()
            }

            if coordinator.isQuickDictationReady {
                LabeledContent("Quick Dictation", value: "Ready")
                Button("Turn off Quick Dictation", role: .destructive) {
                    quickDictationEnabled = false
                }
            }

            if let message = coordinator.message {
                Text(message)
                    .foregroundStyle(coordinator.hasError ? .red : .secondary)
            }

            if coordinator.isRecording {
                Button("Finish recording") { coordinator.requestFinish() }
                    .brandProminentButton()
                Button("Cancel", role: .destructive) { coordinator.cancel() }
            } else {
                Button("Start microphone test") { coordinator.startInAppTest() }
                    .brandProminentButton()
            }
        } header: {
            Text("Current session")
        } footer: {
            sessionFooter
        }
    }

    @ViewBuilder private var sessionFooter: some View {
        if coordinator.isRecording {
            Text("Recording continues while you return to the previous app.")
        } else if coordinator.isQuickDictationReady,
                  let expiresAt = coordinator.quickDictationExpiresAt
        {
            Text(
                "Microphone ready until "
                    + expiresAt.formatted(date: .omitted, time: .shortened)
                    + ". Later Dictate taps stay in the current app."
            )
        }
    }

    private var transcriptSection: some View {
        Section("Transcripts") {
            if let transcript = coordinator.transcript, !transcript.isEmpty {
                Text(transcript)
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = transcript
                } label: {
                    Label("Copy latest transcript", systemImage: "doc.on.doc")
                }
            }
            NavigationLink {
                TranscriptHistoryView()
            } label: {
                Label("All transcripts", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    private var practiceSection: some View {
        Section {
            TextField("Switch to the vocaphone keyboard here", text: $testText, axis: .vertical)
                .lineLimit(3...6)

            if coordinator.isDictatingIntoContainingApp {
                // Dictating into this field needs no app switch, so the flow is
                // explained inline instead of behind a full-screen hand-off.
                HStack(spacing: 10) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Listening")
                    Spacer()
                    RecordingMeter()
                        .frame(width: 90)
                }
                .accessibilityElement(children: .combine)

                Button("Finish recording") { coordinator.requestFinish() }
                    .brandProminentButton()
                Button("Cancel", role: .destructive) { coordinator.cancel() }
            }
        } header: {
            Text("Try the keyboard")
        } footer: {
            if coordinator.isDictatingIntoContainingApp {
                Text("Tap Finish on the keyboard and the transcript drops into this field.")
            } else {
                Text(
                    "Dictating here keeps you in vocaphone. From another app, the keyboard "
                        + "opens vocaphone to record — swipe back once recording begins, then "
                        + "tap Finish in the keyboard."
                )
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

    var body: some View {
        ProgressView(value: Double(coordinator.meterLevel))
            .tint(.red)
    }
}

private struct RecordingPulse: View {
    @Environment(RecordingCoordinator.self) private var coordinator

    private var level: CGFloat {
        coordinator.isKeyboardRecording ? CGFloat(coordinator.meterLevel) : 0.42
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.12))
                .frame(width: 108, height: 108)
            Circle()
                .fill(.red)
                .frame(width: 58 + level * 18, height: 58 + level * 18)
                .animation(.linear(duration: 0.12), value: level)
            Image(systemName: "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
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
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                RecordingPulse()

                VStack(spacing: 8) {
                    Text("vocaphone is listening")
                        .font(.title2.weight(.semibold))
                    Text(startedAt, style: .timer)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 6) {
                    Label(
                        "Swipe right across the bottom edge to go back",
                        systemImage: "arrow.turn.up.left"
                    )
                    .font(.headline)
                    Text(
                        "Recording continues in the background. When the keyboard reappears, "
                            + "tap Finish — or use Finish in the Dynamic Island."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                Spacer()

                VStack(spacing: 8) {
                    Button("Finish recording here instead", action: finish)
                        .brandProminentButton()
                        .controlSize(.large)
                    Button("Cancel recording", role: .destructive, action: cancel)
                        .font(.subheadline)
                }
            }
            .padding(24)
        }
    }
}
