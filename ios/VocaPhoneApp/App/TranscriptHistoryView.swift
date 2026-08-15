import SwiftUI
import UIKit

/// The transcript library.
///
/// It was a flat list with copy and share. What was missing, in the order it
/// was missed: search, a way to *delete* — in a product whose pitch is that your
/// words stay yours — day grouping, filters, and somewhere to read a long
/// transcript that the row clips.
struct TranscriptHistoryView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @State private var records: [SessionRecord] = []
    @State private var filter = TranscriptHistoryModel.Filter()
    @State private var copiedID: UUID?
    @State private var pendingDeletion: SessionRecord?

    init() {}

#if DEBUG
    /// Preview seam: the filter is `@State`, so a canvas has no other way to
    /// reach "nothing matches" — the state most easily confused with "no
    /// transcripts yet", and the one whose wording exists to tell them apart.
    init(previewFilter: TranscriptHistoryModel.Filter) {
        _filter = State(initialValue: previewFilter)
    }
#endif

    private var sections: [TranscriptHistoryModel.Section] {
        TranscriptHistoryModel.sections(
            TranscriptHistoryModel.filtered(records, filter: filter)
        )
    }

    var body: some View {
        List {
            if sections.isEmpty {
                ContentUnavailableView(
                    records.isEmpty ? "No transcripts yet" : "Nothing matches",
                    systemImage: records.isEmpty ? "text.quote" : "magnifyingglass",
                    description: Text(
                        TranscriptHistoryModel.emptyMessage(
                            for: filter,
                            hasAnyRecords: !records.isEmpty
                        )
                    )
                )
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.records) { record in
                        NavigationLink {
                            TranscriptDetailView(record: record) {
                                Task { await delete(record) }
                            }
                        } label: {
                            row(for: record)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await delete(record) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Transcripts")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter.query, prompt: "Search transcripts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    /// Route and style, the two facts every row already shows. A filter over
    /// something invisible would be a filter nobody trusts.
    private var filterMenu: some View {
        Menu {
            Picker("Where it ran", selection: $filter.route) {
                Text("Any source").tag(SessionProcessingLocation?.none)
                Text("On this iPhone").tag(SessionProcessingLocation?.some(.onDevice))
                Text("Your gateway").tag(SessionProcessingLocation?.some(.gateway))
            }
            Picker("Writing style", selection: $filter.style) {
                Text("Any style").tag(WritingStyle?.none)
                ForEach(WritingStyle.allCases) { style in
                    Text(style.displayName).tag(WritingStyle?.some(style))
                }
            }
            if filter.hasChips {
                Button("Clear filters", role: .destructive) {
                    filter.route = nil
                    filter.style = nil
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: filter.hasChips
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
    }

    @ViewBuilder
    private func row(for record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: VocaMetrics.related - 2) {
            // Metadata small and first; the transcript is the content and
            // everything else on the row is a caption for it.
            HStack(spacing: VocaMetrics.related) {
                Text(TranscriptHistoryModel.timestamp(for: record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let style = WritingStyle(rawValue: record.style) {
                    Label(style.displayName, systemImage: style.symbolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let location = record.processingLocation {
                    Label(
                        location == .onDevice ? "This iPhone" : "Your gateway",
                        systemImage: location == .onDevice ? "iphone" : "server.rack"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }
            Text(record.transcript ?? "")
                .font(.body)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, VocaMetrics.tight)
    }

    private func delete(_ record: SessionRecord) async {
        await coordinator.deleteTranscript(record.sessionID)
        await reload()
    }

    /// Reading and decoding session files is file work, so it stays off the main
    /// actor and only the assignment comes back.
    private func reload() async {
        records = await coordinator.loadRecentTranscripts()
        copiedID = nil
    }
}

/// One transcript, unclipped and selectable, with everything that can be done
/// to it in one place.
struct TranscriptDetailView: View {
    let record: SessionRecord
    let delete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false
    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VocaMetrics.grouping) {
                VocaCard {
                    Text(record.transcript ?? "")
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VocaCard {
                    VStack(alignment: .leading, spacing: VocaMetrics.related + 2) {
                        VocaSectionHeader(title: "About this transcript")
                        LabeledContent(
                            "Recorded",
                            value: record.createdAt.formatted(date: .abbreviated, time: .shortened)
                        )
                        LabeledContent("Where it ran", value: routeName)
                        if let style = WritingStyle(rawValue: record.style) {
                            LabeledContent("Writing style", value: style.displayName)
                        }
                        LabeledContent("Words", value: "\(wordCount)")
                    }
                }

                VStack(spacing: VocaMetrics.related) {
                    VocaPrimaryButton(
                        title: didCopy ? "Copied" : "Copy transcript",
                        symbol: didCopy ? "checkmark" : "doc.on.doc"
                    ) {
                        UIPasteboard.general.string = record.transcript
                        didCopy = true
                    }
                    if let transcript = record.transcript {
                        ShareLink(item: transcript) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    Button("Delete transcript", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal, VocaMetrics.padding)
            .padding(.vertical, VocaMetrics.grouping)
        }
        .background(Color.vocaCanvas)
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                delete()
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("It is removed from this iPhone and cannot be recovered.")
        }
    }

    private var routeName: String {
        switch record.processingLocation {
        case .onDevice: "On this iPhone"
        case .gateway: "Your gateway"
        // A record from before the route was written down. Saying so is better
        // than guessing which one it was.
        case nil: "Not recorded"
        }
    }

    private var wordCount: Int {
        (record.transcript ?? "").split(whereSeparator: \.isWhitespace).count
    }
}

#if DEBUG

// MARK: - Previews

// The populated state is the one the search, the filters and the day grouping
// were built for, and the one that needs ninety real dictations to reach.

#Preview("History — populated") {
    PreviewHost(coordinator: .previewIdle()) {
        NavigationStack { TranscriptHistoryView() }
    }
}

#Preview("History — no transcripts yet") {
    PreviewHost(
        coordinator: RecordingCoordinator(
            preview: nil,
            setupStatus: PreviewFixtures.setupComplete,
            transcripts: []
        )
    ) {
        NavigationStack { TranscriptHistoryView() }
    }
}

#Preview("History — nothing matches the search") {
    PreviewHost(coordinator: .previewIdle()) {
        NavigationStack {
            TranscriptHistoryView(
                previewFilter: TranscriptHistoryModel.Filter(query: "quarterly budget")
            )
        }
    }
}

#Preview("History — nothing matches the filters") {
    PreviewHost(coordinator: .previewIdle()) {
        NavigationStack {
            TranscriptHistoryView(
                previewFilter: TranscriptHistoryModel.Filter(route: .onDevice, style: .excited)
            )
        }
    }
}

/// The row's metadata is a three-item `HStack` with no wrapping, which is the
/// finding this matrix exists to make visible.
#Preview("History — matrix", traits: .sizeThatFitsLayout) {
    PreviewMatrix(coordinator: .previewIdle()) {
        NavigationStack { TranscriptHistoryView() }
    }
}

#Preview("Transcript detail — long") {
    PreviewHost {
        NavigationStack {
            TranscriptDetailView(
                record: PreviewFixtures.record(
                    state: .completed,
                    transcript: PreviewFixtures.longTranscript,
                    processingLocation: .onDevice,
                    style: .formal
                ),
                delete: {}
            )
        }
    }
}

/// A record written before the route was stored, which is the only case that
/// says "Not recorded" rather than naming a place.
#Preview("Transcript detail — route unknown") {
    PreviewHost {
        NavigationStack {
            TranscriptDetailView(
                record: PreviewFixtures.record(
                    state: .completed,
                    transcript: PreviewFixtures.shortTranscript,
                    processingLocation: nil
                ),
                delete: {}
            )
        }
    }
}

#Preview("Transcript detail — matrix", traits: .sizeThatFitsLayout) {
    PreviewMatrix {
        NavigationStack {
            TranscriptDetailView(
                record: PreviewFixtures.record(
                    state: .completed,
                    transcript: PreviewFixtures.verboseTranscript
                ),
                delete: {}
            )
        }
    }
}
#endif
