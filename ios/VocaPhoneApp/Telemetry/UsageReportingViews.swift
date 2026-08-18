import SwiftUI

/// The onboarding step that asks.
///
/// Deliberately placed at the end of guided setup, after the user has a working
/// transcript rather than while they are still deciding whether the app is worth
/// their time. Both buttons carry the same weight: no greyed-out decline, and
/// nothing that makes saying no look like a mistake. The controls are on this
/// screen rather than behind a link, because a notice whose switch lives
/// somewhere else is not a choice.
struct UsageReportingSetupSection: View {
    let onDecision: (Bool) -> Void

    @State private var isShowingPayload = false

    var body: some View {
        Section {
            Button(UsageReportingCopy.turnOn) { onDecision(true) }
                .brandProminentButton()
                .listRowSeparator(.hidden)

            Button(UsageReportingCopy.notNow) { onDecision(false) }
                .listRowSeparator(.hidden)

            Button(UsageReportingCopy.seeWhatIsSent) { isShowingPayload = true }
                .font(.subheadline)
        } header: {
            Text(UsageReportingCopy.title)
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(UsageReportingCopy.whatIsSent)
                Text(UsageReportingCopy.whatIsNeverSent)
                Text(UsageReportingCopy.changeLater)
            }
        }
        .sheet(isPresented: $isShowingPayload) { PendingPayloadSheet() }
    }
}

/// The Privacy-screen section: the same words, the switch, and the viewer.
struct UsageReportingSettingsSection: View {
    // Read from the app group rather than seeded once into @State: the setup
    // card writes the same key, so a copy captured at init would show a stale
    // value and write it back on the next flip.
    @AppStorage(
        UserDefaultsTelemetryPreferences.enabledKey,
        store: UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)
    ) private var isEnabled = TelemetryConfig.defaultEnabled
    @State private var isShowingPayload = false

    private let preferences = UserDefaultsTelemetryPreferences()

    var body: some View {
        Section {
            Toggle("Send anonymous usage data", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, enabled in
                    Task { await Telemetry.shared.setEnabled(enabled) }
                    // Answering the switch here counts as answering the
                    // question, or guided setup keeps asking someone to opt into
                    // something they already turned on.
                    preferences.hasBeenAsked = true
                }

            Button(UsageReportingCopy.seeWhatIsSent) { isShowingPayload = true }
        } header: {
            Text(UsageReportingCopy.settingsTitle)
        } footer: {
            VStack(alignment: .leading, spacing: VocaMetrics.related) {
                Text(UsageReportingCopy.whatIsSent)
                Text(UsageReportingCopy.whatIsNeverSent)
                // Disclosed rather than discovered. A `telemetry_disabled` event
                // that a user finds by packet capture is far more damaging than
                // not knowing the opt-out rate at all.
                Text(UsageReportingCopy.noIdentifier + " " + UsageReportingCopy.optOutIsLogged)
            }
        }
        .sheet(isPresented: $isShowingPayload) { PendingPayloadSheet() }
    }
}

/// The literal JSON the next flush would POST.
///
/// Rendered rather than summarised on purpose: this is the screen that makes the
/// privacy claim checkable by the person it is made to, and it is self-enforcing
/// — if someone later adds a field to the payload it appears here without anyone
/// remembering to update a description of it.
struct PendingPayloadSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let payload = Telemetry.shared.pendingPayload()
                let status = Telemetry.shared.deliveryStatus
                if !status.isEmpty {
                    // Shown whether or not anything is queued: an empty queue is
                    // exactly the case where "did it send, or was it never
                    // recorded?" needs answering.
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top)
                }
                if payload.isEmpty {
                    Text(UsageReportingCopy.emptyQueue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    VStack(alignment: .leading, spacing: VocaMetrics.related) {
                        Text(
                            "\(Telemetry.shared.pendingCount) waiting · "
                                + "POST \(TelemetryConfig.host)\(TelemetryConfig.ingestPath)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        // Monospaced and horizontally scrollable rather than
                        // wrapped: wrapped JSON is unreadable, and this screen
                        // is worthless if it cannot actually be read.
                        ScrollView(.horizontal) {
                            Text(payload)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("What's sent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
