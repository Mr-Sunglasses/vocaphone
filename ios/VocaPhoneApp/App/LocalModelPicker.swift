import SwiftUI

/// The on-device model list, shared by setup and settings.
///
/// The catalog is deliberately large, so this shows only what this iPhone has
/// the memory for. Installed models and downloadable models stay in separate
/// sections so the model currently available for use is easy to find, and every
/// row says the same five things in the same order: what it is, how big it is,
/// what languages it covers, what state it is in, and the one action available.
struct LocalModelPicker: View {
    let manager: LocalModelManager
    /// Setup needs its status line refreshed on every change; Settings does not.
    var onChange: () -> Void = {}

    @State private var downloadTask: Task<Void, Never>?
    @State private var modelLoadTask: Task<Void, Never>?
    @State private var modelLoadError: String?
    @State private var availableModelsExpanded = false
    @State private var pendingDeletion: LocalModelDescriptor?

    private var usable: [LocalModelDescriptor] { LocalModelCatalog.usableOnDevice }

    private var installedModels: [LocalModelDescriptor] {
        usable.filter { manager.isDownloaded($0.id) || state(for: $0) != .notDownloaded }
    }

    private var availableModels: [LocalModelDescriptor] {
        usable.filter { state(for: $0) == .notDownloaded }
    }

    /// The five states a model can be in, named once so every surface uses the
    /// same words for them.
    private enum ModelState: Equatable {
        case notDownloaded
        case downloading
        case verifying
        case failedIntegrity
        case loading
        case ready
        case selected

        var label: String {
            switch self {
            case .notDownloaded: "Not downloaded"
            case .downloading: "Downloading"
            case .verifying: "Verifying"
            case .failedIntegrity: "Failed verification"
            case .loading: "Loading"
            case .ready: "Ready"
            case .selected: "In use"
            }
        }

        var status: VocaStatus {
            switch self {
            case .notDownloaded: .inactive
            case .downloading, .verifying, .loading: .working
            case .failedIntegrity: .failed
            case .ready, .selected: .ready
            }
        }
    }

    private func state(for model: LocalModelDescriptor) -> ModelState {
        if manager.downloadingModelID == model.id { return .downloading }
        if manager.loadingModelID == model.id { return .loading }
        if manager.verifyingModelIDs.contains(model.id) { return .verifying }
        if manager.failedIntegrityModelIDs.contains(model.id) { return .failedIntegrity }
        guard manager.isDownloaded(model.id) else { return .notDownloaded }
        return LocalTranscriptionPreferences.modelIdentifier == model.id ? .selected : .ready
    }

    @ViewBuilder
    var body: some View {
        if usable.isEmpty {
            Section {
                Text("No on-device model fits this iPhone yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            if !installedModels.isEmpty {
                Section("On this iPhone") {
                    ForEach(installedModels) { model in
                        row(for: model)
                    }
                }
            }

            Section("Available to download") {
                if availableModels.isEmpty {
                    Text("All compatible models are already on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup(isExpanded: $availableModelsExpanded) {
                        ForEach(availableModels) { model in
                            row(for: model)
                        }
                    } label: {
                        Text(
                            "\(availableModels.count) compatible model"
                                + (availableModels.count == 1 ? "" : "s")
                        )
                        .font(.subheadline)
                    }
                }
            }

            if manager.message != nil || modelLoadError != nil {
                Section {
                    if let message = manager.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(manager.hasError ? Color.vocaError : .secondary)
                    }
                    if let modelLoadError {
                        Text(modelLoadError)
                            .font(.footnote)
                            .foregroundStyle(Color.vocaError)
                    }
                }
            }
        }
    }

    private func row(for model: LocalModelDescriptor) -> some View {
        let state = state(for: model)
        return VStack(alignment: .leading, spacing: VocaMetrics.related + 2) {
            VocaStatusLine(
                status: state.status,
                title: model.displayName,
                detail: detail(for: model, state: state)
            )

            switch state {
            case .downloading:
                VStack(alignment: .leading, spacing: VocaMetrics.related) {
                    HStack {
                        Text("Downloading")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(manager.progress * 100))%")
                            .font(.subheadline.monospacedDigit())
                    }
                    ProgressView(value: manager.progress)
                    Button("Cancel") {
                        downloadTask?.cancel()
                        downloadTask = nil
                    }
                    .buttonStyle(.bordered)
                }
            case .verifying, .loading:
                HStack(spacing: VocaMetrics.related + 2) {
                    ProgressView()
                    Text(
                        state == .verifying
                            ? "Checking every file against its published SHA-256."
                            : manager.loadingMessage ?? "Loading the model…"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            // `.frame(maxWidth:)` outside a button stretches its *layout* and
            // leaves the control its natural size, which is how these ended up
            // the same compact pill as the destructive action below them. The
            // width belongs on the label.
            case .failedIntegrity:
                Button { download(model) } label: {
                    Text("Download again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            case .notDownloaded:
                Button { download(model) } label: {
                    Text("Download \(model.sizeLabel)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isBusy)
            case .ready:
                VocaPrimaryButton(title: "Use this model") { prepare(model) }
                    .disabled(isBusy)
            case .selected:
                EmptyView()
            }

            if state == .ready || state == .selected || state == .failedIntegrity {
                // Centred and compact, with room above it. "Use this model" is
                // a full-width filled button, so a full-width destructive one
                // directly beneath it shares an edge with the very action it
                // must never be confused for.
                VocaDestructiveButton(title: "Delete model") {
                    pendingDeletion = model
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, VocaMetrics.related)
            }
        }
        .padding(.vertical, VocaMetrics.tight)
        .confirmationDialog(
            "Delete \(pendingDeletion?.displayName ?? "this model")?",
            isPresented: Binding(
                get: { pendingDeletion == model },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                manager.deleteReportingResult(model)
                pendingDeletion = nil
                onChange()
            }
            Button("Keep", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(
                "\(model.sizeLabel) will be freed. You can download it again at any "
                    + "time; dictating offline needs a model on this iPhone."
            )
        }
    }

    private var isBusy: Bool {
        manager.downloadingModelID != nil || manager.loadingModelID != nil
    }

    /// Size before download, languages before selection, and — for a failed
    /// integrity check — what actually went wrong, because "download failed" and
    /// "the files do not match what was published" call for different responses.
    private func detail(for model: LocalModelDescriptor, state: ModelState) -> String {
        switch state {
        case .failedIntegrity:
            return "The downloaded files do not match their published checksums, so "
                + "the model will not be loaded. Download it again."
        case .selected:
            return "\(model.languages) · in use for dictation on this iPhone"
        case .ready:
            return "\(model.languages) · verified and ready to use offline"
        default:
            var detail = "\(model.sizeLabel) · \(model.languages)"
            if model.id == LocalModelCatalog.recommended.id {
                detail += " · recommended"
            }
            return detail
        }
    }

    private func download(_ model: LocalModelDescriptor) {
        downloadTask?.cancel()
        downloadTask = Task { @MainActor in
            do {
                try await manager.download(model)
            } catch is CancellationError {
                // The picker shows cancellation as a normal action.
            } catch {
                // LocalModelManager publishes the actionable error.
            }
            onChange()
            downloadTask = nil
        }
    }

    private func prepare(_ model: LocalModelDescriptor) {
        modelLoadError = nil
        modelLoadTask?.cancel()
        modelLoadTask = Task { @MainActor in
            do {
                try await manager.prepare(
                    model,
                    language: KeyboardPreferences.effectiveTranscriptionLanguage.rawValue
                )
                guard !Task.isCancelled else { return }
                LocalTranscriptionPreferences.modelIdentifier = model.id
                LocalTranscriptionPreferences.enabled = true
                onChange()
            } catch is CancellationError {
                // The picker does not expose cancellation for engine loading;
                // cancellation here only prevents a stale selection commit.
            } catch {
                modelLoadError = "Could not load \(model.displayName): "
                    + error.localizedDescription
            }
            modelLoadTask = nil
        }
    }
}
