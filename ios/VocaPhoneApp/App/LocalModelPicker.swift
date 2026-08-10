import SwiftUI

/// The on-device model list, shared by setup and settings.
///
/// The catalog is deliberately large, so this shows only what this iPhone has
/// the memory for. Installed models and downloadable models stay in separate
/// sections so the model currently available for use is easy to find.
struct LocalModelPicker: View {
    let manager: LocalModelManager
    /// Setup needs its rows indented and its status line refreshed on every
    /// change; Settings does not.
    var leadingPadding: CGFloat = 0
    var onChange: () -> Void = {}

    @State private var downloadTask: Task<Void, Never>?
    @State private var modelLoadTask: Task<Void, Never>?
    @State private var modelLoadError: String?
    @State private var availableModelsExpanded = false

    private var usable: [LocalModelDescriptor] { LocalModelCatalog.usableOnDevice }

    private var installedModels: [LocalModelDescriptor] {
        usable.filter { manager.isDownloaded($0.id) }
    }

    private var availableModels: [LocalModelDescriptor] {
        usable.filter { !manager.isDownloaded($0.id) }
    }

    @ViewBuilder
    var body: some View {
        if usable.isEmpty {
            Text("No on-device model fits this iPhone yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, leadingPadding)
        } else {
            if !installedModels.isEmpty {
                Section {
                    ForEach(installedModels) { model in
                        row(for: model)
                    }
                } header: {
                    Text("Installed models")
                        .padding(.leading, leadingPadding)
                }
            }

            Section {
                if availableModels.isEmpty {
                    Text("All compatible models are installed.")
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
                                + " available to download"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Available models")
                    .padding(.leading, leadingPadding)
            }

            if let message = manager.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(manager.hasError ? .red : .secondary)
                    .padding(.leading, leadingPadding)
            }
            if let modelLoadError {
                Text(modelLoadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.leading, leadingPadding)
            }
        }
    }

    private func row(for model: LocalModelDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                Text(detail(for: model))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if manager.downloadingModelID == model.id {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Downloading model…")
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
            } else if manager.loadingModelID == model.id {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(manager.loadingMessage ?? "Loading model… Please wait.")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            } else if manager.isDownloaded(model.id) {
                if LocalTranscriptionPreferences.modelIdentifier == model.id {
                    Label("Selected model", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Button("Use this model") {
                        prepare(model)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(
                        manager.downloadingModelID != nil || manager.loadingModelID != nil
                    )
                }
            } else {
                Button("Download") {
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
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(
                    manager.downloadingModelID != nil || manager.loadingModelID != nil
                )
            }
        }
    }

    private func detail(for model: LocalModelDescriptor) -> String {
        var detail = "\(model.sizeLabel) · \(model.languages)"
        if model.id == LocalModelCatalog.recommended.id {
            detail += " · recommended"
        }
        return detail
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
                modelLoadError = "Could not load \(model.displayName): \(error.localizedDescription)"
            }
            modelLoadTask = nil
        }
    }
}
