import SwiftUI
import UIKit

/// Transcripts were previously visible only as the single latest result on the
/// main screen, even though every session is already persisted.
struct TranscriptHistoryView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @State private var records: [SessionRecord] = []
    @State private var copiedID: UUID?

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView(
                    "No transcripts yet",
                    systemImage: "text.quote",
                    description: Text("Dictations you complete will be listed here.")
                )
            } else {
                ForEach(records) { record in
                    row(for: record)
                }
            }
        }
        .navigationTitle("Transcripts")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .refreshable { reload() }
    }

    @ViewBuilder
    private func row(for record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let style = WritingStyle(rawValue: record.style) {
                    Label(style.displayName, systemImage: style.symbolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(record.transcript ?? "")
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Button {
                    UIPasteboard.general.string = record.transcript
                    copiedID = record.sessionID
                } label: {
                    Label(
                        copiedID == record.sessionID ? "Copied" : "Copy",
                        systemImage: copiedID == record.sessionID
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderless)
                .font(.footnote)

                if let transcript = record.transcript {
                    ShareLink(item: transcript) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        records = coordinator.recentTranscripts()
        copiedID = nil
    }
}
