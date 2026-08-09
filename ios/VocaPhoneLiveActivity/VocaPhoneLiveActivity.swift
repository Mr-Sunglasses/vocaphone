import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VocaPhoneWidgetBundle: WidgetBundle {
    var body: some Widget {
        VocaPhoneRecordingActivity()
    }
}

struct VocaPhoneRecordingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VocaPhoneActivityAttributes.self) { context in
            HStack(spacing: 14) {
                VocaPhoneLogo(size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("vocaphone")
                        .font(.headline)
                    Text(context.state.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if context.state.canFinish {
                        Text(context.state.startedAt ?? context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if context.state.canFinish,
                   let sessionID = context.state.sessionID ?? Optional(context.attributes.sessionID)
                {
                    Button(intent: FinishRecordingIntent(sessionID: sessionID)) {
                        Label("Finish", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
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
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.canFinish,
                       let sessionID = context.state.sessionID ?? Optional(context.attributes.sessionID)
                    {
                        Button(intent: FinishRecordingIntent(sessionID: sessionID)) {
                            Label("Finish recording", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
            } compactLeading: {
                VocaPhoneLogo(size: 18)
            } compactTrailing: {
                Text(compactLabel(for: context.state.effectivePhase))
                    .font(.caption2.bold())
                    .foregroundStyle(
                        context.state.effectivePhase == .recording ? Color.red : Color.brand
                    )
            } minimal: {
                VocaPhoneLogo(size: 18)
            }
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
            .accessibilityLabel("Vocaphone")
    }
}
