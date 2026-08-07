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
                Image(systemName: context.state.canFinish ? "waveform.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(context.state.canFinish ? .red : .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("vocaphone")
                        .font(.headline)
                    Text(context.state.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if context.state.canFinish {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if context.state.canFinish {
                    Button(intent: FinishRecordingIntent(sessionID: context.attributes.sessionID)) {
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
                    Image(systemName: "waveform.circle.fill")
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.canFinish {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.canFinish {
                        Button(intent: FinishRecordingIntent(sessionID: context.attributes.sessionID)) {
                            Label("Finish recording", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text(context.state.canFinish ? "REC" : "DONE")
                    .font(.caption2.bold())
                    .foregroundStyle(context.state.canFinish ? .red : .green)
            } minimal: {
                Image(systemName: context.state.canFinish ? "waveform" : "checkmark")
                    .foregroundStyle(context.state.canFinish ? .red : .green)
            }
        }
    }
}
