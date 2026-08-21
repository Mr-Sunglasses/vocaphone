import SwiftUI

/// The containing-app surface for a dictation started in another app. The
/// keyboard cannot return the user to that app, so this view teaches the real
/// system gesture once and then stays useful when the user finishes recording
/// here instead.
struct KeyboardHandoffView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let record: SessionRecord
    let presentation: KeyboardHandoffPresentation

    var body: some View {
        ZStack {
            Color.vocaCanvas
                .ignoresSafeArea()

            if presentation.kind == .recording {
                recordingHandoff
            } else {
                statusHandoff
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var recordingHandoff: some View {
        ScrollView {
            VStack(spacing: VocaMetrics.section) {
                header

                VStack(spacing: VocaMetrics.related) {
                    Text("Keep speaking")
                        .font(.largeTitle.weight(.bold))
                    Text("Swipe right across the bottom edge to return")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Recording continues while you switch apps.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                SwipeBackCoach(reduceMotion: reduceMotion, prominent: true)

                VStack(spacing: VocaMetrics.related) {
                    Button {
                        perform(.finish)
                    } label: {
                        Label("Can't swipe back? Finish here instead", systemImage: "stop.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: VocaMetrics.minimumTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityHint(primaryHint)

                    Button("Cancel dictation", role: .destructive) {
                        coordinator.cancel()
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: VocaMetrics.minimumTarget)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, VocaMetrics.grouping)
            .padding(.vertical, VocaMetrics.section)
            .frame(maxWidth: .infinity, minHeight: 720)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            realBottomEdgeCue
        }
    }

    private var realBottomEdgeCue: some View {
        VStack(spacing: 8) {
            Label("Swipe at the real iPhone bottom edge", systemImage: "arrow.down")
                .font(.headline)

            HStack(spacing: VocaMetrics.related) {
                Text("Then swipe right")
                Rectangle()
                    .fill(Color.brand)
                    .frame(height: 3)
                Image(systemName: "arrow.right")
                    .font(.headline.weight(.bold))
            }
            .font(.subheadline.weight(.bold))
        }
        .foregroundStyle(Color.brand)
        .padding(.horizontal, VocaMetrics.grouping)
        .padding(.vertical, VocaMetrics.padding)
        .background(Color.vocaSurface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.vocaBorder)
                .frame(height: 1)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("At the real bottom edge of this iPhone, swipe right.")
    }

    private var statusHandoff: some View {
        ScrollView {
            VStack(spacing: VocaMetrics.grouping) {
                header
                visual
                instruction
                actions
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, VocaMetrics.grouping)
            .padding(.vertical, VocaMetrics.section)
            .frame(maxWidth: .infinity, minHeight: 620)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: VocaMetrics.related) {
            Label(presentation.title, systemImage: symbolName)
                .font(.headline)
                .foregroundStyle(statusColor)
            Spacer()
            if presentation.kind == .recording {
                Text(record.createdAt, style: .timer)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Elapsed recording time")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var visual: some View {
        switch presentation.kind {
        case .recording:
            VStack(spacing: VocaMetrics.padding) {
                HandoffRecordingMark(level: coordinator.meterLevel, reduceMotion: reduceMotion)
                RecordingMeter()
                    .frame(maxWidth: 220)
            }
            .padding(.vertical, VocaMetrics.related)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording")
            .accessibilityValue("Voice level \(Int(coordinator.meterLevel * 100)) percent")
        case .processing:
            ProgressView()
                .controlSize(.large)
                .tint(Color.vocaWarning)
                .frame(height: 112)
                .accessibilityLabel("Working")
        case .ready:
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(Color.brand)
                .frame(height: 112)
                .accessibilityHidden(true)
        case .recoverableFailure:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(Color.vocaError)
                .frame(height: 112)
                .accessibilityHidden(true)
        }
    }

    private var instruction: some View {
        VocaCard(padding: VocaMetrics.padding) {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(presentation.detail)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if presentation.kind == .ready,
                          let transcript = record.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !transcript.isEmpty
                {
                    Text(transcript)
                        .font(.body)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(VocaMetrics.related)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.vocaRecessedSurface,
                            in: RoundedRectangle(cornerRadius: VocaMetrics.fieldRadius, style: .continuous)
                        )
                        .accessibilityLabel("Transcript preview")
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: VocaMetrics.related) {
            if let title = presentation.primaryTitle {
                VocaPrimaryButton(title: title, symbol: primarySymbol) {
                    perform(presentation.primaryAction)
                }
                .accessibilityHint(primaryHint)
            }

            if presentation.showsCancel {
                Button("Cancel dictation", role: .destructive) {
                    coordinator.cancel()
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: VocaMetrics.minimumTarget)
                .accessibilityHint("Discards this dictation.")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var statusColor: Color {
        switch presentation.kind {
        case .recording: .vocaRecording
        case .processing: .vocaWarning
        case .ready: .brand
        case .recoverableFailure: .vocaError
        }
    }

    private var symbolName: String {
        switch presentation.kind {
        case .recording: "record.circle"
        case .processing: "waveform"
        case .ready: "checkmark.circle.fill"
        case .recoverableFailure: "exclamationmark.triangle.fill"
        }
    }

    private var primarySymbol: String? {
        switch presentation.primaryAction {
        case .finish: "stop.fill"
        case .retry: "arrow.clockwise"
        case .none: nil
        }
    }

    private var primaryHint: String {
        switch presentation.primaryAction {
        case .finish:
            "Stops recording and starts speech to text. Return to the keyboard to insert the result."
        case .retry:
            "Sends the preserved recording again."
        case .none:
            ""
        }
    }

    private func perform(_ action: KeyboardHandoffPresentation.PrimaryAction) {
        switch action {
        case .finish:
            coordinator.requestFinish()
        case .retry:
            coordinator.retryPreservedRecording()
        case .none:
            break
        }
    }

}

private struct HandoffRecordingMark: View {
    let level: Float
    let reduceMotion: Bool

    private var size: CGFloat {
        reduceMotion ? 64 : 64 + CGFloat(level) * 18
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.vocaRecording.opacity(0.12))
                .frame(width: 116, height: 116)
            Circle()
                .fill(Color.vocaRecording)
                .frame(width: size, height: size)
                .animation(reduceMotion ? nil : .linear(duration: 0.12), value: level)
            Image(systemName: "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

#if DEBUG

#Preview("Handoff — recording") {
    PreviewHost(
        coordinator: .preview(
            .recording,
            startedInApp: false,
            meterLevel: 0.46,
            isRecording: true
        )
    ) {
        let record = PreviewFixtures.record(state: .recording, startedInApp: false)
        KeyboardHandoffView(
            record: record,
            presentation: KeyboardHandoffPresentation.make(record)!
        )
    }
}

#Preview("Handoff — ready") {
    PreviewHost {
        let record = PreviewFixtures.record(
            state: .readyToInsert,
            transcript: PreviewFixtures.shortTranscript,
            startedInApp: false
        )
        KeyboardHandoffView(
            record: record,
            presentation: KeyboardHandoffPresentation.make(record)!
        )
    }
}
#endif
