import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VocaPhoneWidgetBundle: WidgetBundle {
    var body: some Widget {
        VocaPhoneRecordingActivity()
    }
}

/// The Lock Screen and Dynamic Island presentations.
///
/// The one thing this surface must never do is imply that vocaphone is
/// recording when it is not. Quick Dictation's standby lights the same iOS
/// microphone indicator as a real capture, so standby is drawn in the neutral
/// brand treatment with the word "standby", and only an actual capture is red.
/// Recording also stops looking like recording the moment capture ends, even
/// though uploading and transcribing continue after it.
struct VocaPhoneRecordingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VocaPhoneActivityAttributes.self) { context in
            HStack(spacing: 14) {
                VocaPhoneLogo(size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("vocaphone")
                        .font(.headline)
                    HStack(spacing: 5) {
                        Image(systemName: symbolName(for: context.state.effectivePhase))
                            .font(.caption)
                            .foregroundStyle(tint(for: context.state.effectivePhase))
                            .accessibilityHidden(true)
                        Text(context.state.status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if context.state.canFinish {
                        Text(context.state.startedAt ?? context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                actionButton(
                    for: context.state,
                    fallbackSessionID: context.attributes.sessionID
                )
            }
            .padding()
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VocaPhoneLogo(size: 28)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.canFinish {
                        Text(context.state.startedAt ?? context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.vocaRecording)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedAction(
                        for: context.state,
                        fallbackSessionID: context.attributes.sessionID
                    )
                }
            } compactLeading: {
                VocaPhoneLogo(size: 18)
            } compactTrailing: {
                Text(compactLabel(for: context.state.effectivePhase))
                    .font(.caption2.bold())
                    .foregroundStyle(tint(for: context.state.effectivePhase))
            } minimal: {
                VocaPhoneLogo(size: 18)
            }
        }
    }

    @ViewBuilder
    private func actionButton(
        for state: VocaPhoneActivityAttributes.ContentState,
        fallbackSessionID: String
    ) -> some View {
        if state.canFinish {
            let sessionID = state.sessionID ?? fallbackSessionID
            Button(intent: FinishRecordingIntent(sessionID: sessionID)) {
                Label("Finish", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.vocaRecording)
        } else if state.effectivePhase == .standby {
            Button(intent: StopQuickDictationIntent()) {
                Label("Turn off", systemImage: "mic.slash.fill")
            }
            .buttonStyle(.bordered)
            .tint(.brand)
        }
    }

    @ViewBuilder
    private func expandedAction(
        for state: VocaPhoneActivityAttributes.ContentState,
        fallbackSessionID: String
    ) -> some View {
        if state.canFinish {
            let sessionID = state.sessionID ?? fallbackSessionID
            Button(intent: FinishRecordingIntent(sessionID: sessionID)) {
                Label("Finish recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.vocaRecording)
        } else if state.effectivePhase == .standby {
            Button(intent: StopQuickDictationIntent()) {
                Label("Turn off Quick Dictation", systemImage: "mic.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.brand)
        }
    }

    /// The same semantic roles the keyboard and the app use. Standby is
    /// deliberately *not* red.
    private func tint(
        for phase: VocaPhoneActivityAttributes.ContentState.Phase
    ) -> Color {
        switch phase {
        case .standby: .brand
        case .recording: .vocaRecording
        case .processing: .vocaWarning
        case .finished: .brand
        }
    }

    private func symbolName(
        for phase: VocaPhoneActivityAttributes.ContentState.Phase
    ) -> String {
        switch phase {
        case .standby: "mic.badge.plus"
        case .recording: "record.circle"
        case .processing: "clock"
        case .finished: "checkmark.circle.fill"
        }
    }

    private func compactLabel(
        for phase: VocaPhoneActivityAttributes.ContentState.Phase
    ) -> String {
        switch phase {
        case .standby: "READY"
        case .recording: "REC"
        case .processing: "•••"
        case .finished: "DONE"
        }
    }
}

private struct VocaPhoneLogo: View {
    let size: CGFloat

    var body: some View {
        Image("VocaPhoneLogo")
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(Color.brand)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("vocaphone")
    }
}
