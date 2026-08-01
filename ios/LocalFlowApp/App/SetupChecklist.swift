import SwiftUI

struct SetupStep: Identifiable {
    let id: String
    let title: String
    let detail: String
    let isComplete: Bool
}

/// The dominant failure mode for this app is an unfinished setup spread across
/// iOS Settings, a gateway, and a permission prompt. Showing the remaining work
/// as a checklist beats burying it in prose.
struct SetupChecklistView: View {
    let steps: [SetupStep]
    let recheck: () -> Void

    var body: some View {
        Section {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: step.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(step.isComplete ? .green : .secondary)
                        .font(.title3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.subheadline.weight(.semibold))
                        Text(step.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(step.isComplete ? "Done" : "Not done")
            }

            Button("Check again", action: recheck)
                .font(.footnote)
        } header: {
            Text("Finish setup")
        } footer: {
            Text("Local Flow needs all three before the keyboard can dictate.")
        }
    }
}
