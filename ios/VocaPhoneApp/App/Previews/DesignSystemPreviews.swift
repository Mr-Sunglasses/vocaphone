#if DEBUG
import SwiftUI

// The token layer, in one place. Every screen is built from these four shapes,
// so anything wrong here is wrong everywhere — and the two states that matter
// most, the disabled primary and the accessibility-size status line, are the two
// that never appear in a screenshot of a working app.
//
// These live apart from `DesignSystem.swift` because the test target compiles
// that file too, and the fixtures below are in the app target only.

#Preview("Status line — every state", traits: .sizeThatFitsLayout) {
    ScrollView {
        VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
            ForEach(
                [
                    VocaStatus.ready,
                    .recording,
                    .working,
                    .attention,
                    .failed,
                    .inactive,
                ],
                id: \.self
            ) { status in
                VocaCard {
                    VocaStatusLine(
                        status: status,
                        title: "Ready to dictate",
                        detail: "Dictate from any app with the vocaphone keyboard."
                    )
                }
            }
        }
        .padding()
        .frame(width: 380)
    }
    .background(Color.vocaCanvas)
}

/// The one place in the app that already handles accessibility sizes, next to
/// itself at default size, so the pattern the rest of the app has to adopt is
/// visible rather than described.
#Preview("Status line — default beside accessibility 5", traits: .sizeThatFitsLayout) {
    HStack(alignment: .top, spacing: 20) {
        ForEach([PreviewVariant.standard, .accessibility]) { variant in
            VStack(spacing: 8) {
                Text(variant.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                PreviewHost(variant) {
                    VocaCard(padding: VocaMetrics.grouping) {
                        VocaStatusLine(
                            status: .attention,
                            title: "Gateway unavailable",
                            detail: "homelabone:8765 did not answer. Your recording is preserved.",
                            isProminent: true
                        )
                    }
                    .padding()
                }
                .frame(width: 340)
            }
        }
    }
    .padding()
}

#Preview("Buttons — enabled, disabled, destructive", traits: .sizeThatFitsLayout) {
    VStack(spacing: VocaMetrics.grouping) {
        VocaPrimaryButton(title: "Dictate here", symbol: "mic.fill") {}
        VocaPrimaryButton(title: "Dictate here", symbol: "mic.fill") {}
            .disabled(true)
        VocaCopyButton(title: "Copy transcript", value: PreviewFixtures.shortTranscript)
        VocaCopyButton(title: "Copy transcript", value: nil)
        VocaDestructiveButton(title: "Delete model") {}
        // Bare text inside a card is roughly 20 pt tall — half the minimum
        // target — and this is what the app uses for Cancel today.
        Button("Cancel", role: .destructive) {}
            .frame(maxWidth: .infinity)
            .font(.subheadline)
    }
    .padding()
    .frame(width: 360)
    .background(Color.vocaCanvas)
}

#Preview("Cards — light and dark", traits: .sizeThatFitsLayout) {
    HStack(alignment: .top, spacing: 20) {
        ForEach([PreviewVariant.standard, .dark]) { variant in
            PreviewHost(variant) {
                VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
                    VocaCard {
                        VStack(alignment: .leading, spacing: VocaMetrics.related) {
                            VocaSectionHeader(title: "Latest transcript")
                            Text(PreviewFixtures.longTranscript)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VocaCard {
                        VStack(alignment: .leading, spacing: VocaMetrics.related) {
                            VocaSectionHeader(
                                title: "Try the keyboard",
                                action: (title: "Clear", perform: {})
                            )
                            Text("A card whose heading carries its own action.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .frame(width: 340)
        }
    }
    .padding()
}
#endif
