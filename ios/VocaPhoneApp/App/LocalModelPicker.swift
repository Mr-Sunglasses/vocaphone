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
    /// Onboarding presents one guided answer; Settings keeps the full catalog.
    var onboarding = false
    var guidanceLanguage = ""

#if DEBUG
    /// Which model a `#Preview` should draw as "In use". Production leaves this
    /// nil and reads the stored preference, because a canvas must not write the
    /// developer's real model selection to reach one row state.
    var previewSelectedModelID: String?
#endif

    @State private var modelLoadTask: Task<Void, Never>?
    @State private var modelLoadError: String?
    @State private var availableModelsExpanded = false
    @State private var pendingDeletion: LocalModelDescriptor?
    @State private var guidancePriority: ModelGuidancePriority = .balanced
    @State private var guidanceLanguageOverride: String?

    /// Read so the card can say what a large download costs before it starts.
    /// Computed rather than stored: a stored property would join the memberwise
    /// initializer, and reading it here tracks the observation just the same.
    private var network: NetworkConditions { NetworkConditions.shared }

    private var usable: [LocalModelDescriptor] { LocalModelCatalog.usableOnDevice }

    private var installedModels: [LocalModelDescriptor] {
        usable.filter { manager.isDownloaded($0.id) || state(for: $0) != .notDownloaded }
    }

    private var guidance: ModelGuidanceResult {
        return LocalModelCatalog.guidance(
            deviceMemoryGB: LocalModelCatalog.deviceMemoryGB,
            intent: ModelGuidanceIntent(
                language: recommendationLanguage,
                priority: guidancePriority
            )
        )
    }

    private var recommendationLanguage: String {
        let requested = guidanceLanguageOverride ?? guidanceLanguage
        if requested.isEmpty || requested == TranscriptionLanguage.automatic.rawValue {
            return LocalModelCatalog.deviceLanguage
        }
        return requested.lowercased()
    }

    private var deviceLanguageName: String {
        TranscriptionLanguage(rawValue: LocalModelCatalog.deviceLanguage)?.displayName
            ?? Locale.current.localizedString(forLanguageCode: LocalModelCatalog.deviceLanguage)
            ?? LocalModelCatalog.deviceLanguage.uppercased()
    }

    private var guidanceLanguageSelection: String {
        let requested = guidanceLanguageOverride ?? guidanceLanguage
        return requested.isEmpty ? TranscriptionLanguage.automatic.rawValue : requested
    }

    private var picks: [ModelPick] {
        if onboarding {
            guard let model = guidance.model else { return [] }
            return [ModelPick(role: .guided, model: model)]
        }
        return LocalModelCatalog.recommendations(
            deviceMemoryGB: LocalModelCatalog.deviceMemoryGB,
            language: recommendationLanguage
        )
    }

    /// Picks not yet on the phone. The installed ones already have a row above
    /// with their real state; repeating them here would say nothing new.
    private var recommendedPicks: [ModelPick] {
        picks.filter { state(for: $0.model) == .notDownloaded }
    }

    private var availableModels: [LocalModelDescriptor] {
        let recommended = Set(recommendedPicks.map(\.model.id))
        return usable.filter { state(for: $0) == .notDownloaded && !recommended.contains($0.id) }
    }

    private var downloadDetailLine: String? {
        let parts = [manager.downloadSizeProgress, manager.downloadTimeRemaining]
        let line = parts.compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// The same guidance run at the other end of the trade-off. Shown as one
    /// concrete swap rather than a grid: the setup card stays a single answer,
    /// but the fact that a small option exists no longer lives only behind a
    /// sheet most people never open.
    private var guidanceAlternative: LocalModelDescriptor? {
        guard onboarding, let current = guidance.model else { return nil }
        let lighter = LocalModelCatalog.guidance(
            deviceMemoryGB: LocalModelCatalog.deviceMemoryGB,
            intent: ModelGuidanceIntent(language: recommendationLanguage, priority: .lighter)
        ).model
        guard let lighter, lighter.id != current.id else { return nil }
        guard state(for: lighter) == .notDownloaded else { return nil }
        return lighter
    }

    private var downloadWarning: DownloadWarning? {
        guard onboarding, let model = guidance.model else { return nil }
        // Nothing to warn about once the transfer is running, and this reads the
        // volume synchronously: the picker redraws on every progress tick.
        guard manager.downloadingModelID == nil, !manager.isDownloaded(model.id) else { return nil }
        return DownloadReadiness.warning(
            sizeBytes: model.sizeBytes,
            freeBytes: manager.availableStorageBytes,
            metered: network.isMetered
        )
    }

    /// The one sentence a warning is worth. Written so it says what to do, not
    /// only what is wrong.
    private func warningHeadline(_ warning: DownloadWarning) -> String {
        switch warning {
        case let .notEnoughStorage(freeBytes, requiredBytes):
            "Needs \(DownloadReadiness.byteLabel(requiredBytes)) free · "
                + "\(DownloadReadiness.byteLabel(freeBytes)) available. Free up space first."
        case let .meteredConnection(sizeBytes):
            "This connection may charge for data · \(DownloadReadiness.byteLabel(sizeBytes)) download."
        }
    }

    private func role(of model: LocalModelDescriptor) -> ModelPickRole? {
        picks.first { $0.model.id == model.id }?.role
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
#if DEBUG
        if let previewSelectedModelID {
            return previewSelectedModelID == model.id ? .selected : .ready
        }
#endif
        return LocalTranscriptionPreferences.modelIdentifier == model.id ? .selected : .ready
    }

    @ViewBuilder
    var body: some View {
        if onboarding {
            onboardingBody
        } else if usable.isEmpty {
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

            if !recommendedPicks.isEmpty {
                Section {
                    ForEach(recommendedPicks, id: \.model.id) { pick in
                        row(for: pick.model)
                    }
                } header: {
                    Text("Recommended for this iPhone")
                } footer: {
                    Text(
                        "Each of these answers a different question. Every one runs "
                            + "on this iPhone; pick the one that matches how you dictate."
                    )
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

    @ViewBuilder
    private var onboardingBody: some View {
        if usable.isEmpty {
            Section {
                Text("No on-device model fits this iPhone yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let model = guidance.model {
            let warning = downloadWarning
            Section {
                Text(guidance.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let warning {
                    Text(warningHeadline(warning))
                        .font(.footnote)
                        // Only the storage case is a hard stop. Painting "you
                        // are on cellular" the same red reads as something
                        // broken rather than a cost worth knowing.
                        .foregroundStyle(warning.isStorage ? Color.vocaError : Color.vocaWarning)
                }
                row(for: model, onboarding: true)
                if let alternative = guidanceAlternative {
                    VStack(alignment: .leading, spacing: VocaMetrics.related) {
                        Text(
                            warning.isStorage
                                ? "\(alternative.displayName) needs only \(alternative.sizeLabel)."
                                : "Need something smaller? \(alternative.displayName) · "
                                    + "\(alternative.sizeLabel)."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        Button {
                            downloadAndUse(alternative)
                        } label: {
                            Text("Use \(alternative.displayName) instead")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isBusy)
                    }
                }
                ModelGuidanceChoiceButton(
                    selection: $guidancePriority,
                    language: guidanceLanguageSelection,
                    deviceLanguageName: deviceLanguageName,
                    enabled: !isBusy,
                    onApply: applyGuidance
                )
            } header: {
                Text("Recommended for you")
            } footer: {
                // Says what the one visible choice was made on, so the "Help me
                // choose" button reads as a way to change an answer rather than
                // as a second, unrelated question.
                Text(
                    "Chosen for \(guidance.languageName) · \(guidancePriority.title). "
                        + "You can switch models later in Settings."
                )
            }

            let otherInstalled = installedModels.filter { $0.id != model.id }
            if !otherInstalled.isEmpty {
                Section("Already on this iPhone") {
                    ForEach(otherInstalled) { installed in
                        row(for: installed)
                    }
                }
            }

            Section("More compatible models") {
                if availableModels.isEmpty {
                    Text("All other compatible models are already on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup(isExpanded: $availableModelsExpanded) {
                        ForEach(availableModels) { available in
                            row(for: available)
                        }
                    } label: {
                        Text("Browse \(availableModels.count) compatible models")
                    }
                }
            }
        } else {
            Section {
                Text(guidance.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Choose another language in Dictation settings, or use your self-hosted gateway.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ModelGuidanceChoiceButton(
                    selection: $guidancePriority,
                    language: guidanceLanguageSelection,
                    deviceLanguageName: deviceLanguageName,
                    enabled: !isBusy,
                    onApply: applyGuidance
                )
            } header: {
                Text("No guided match")
            }
            Section("Compatible models") {
                ForEach(usable) { model in
                    row(for: model)
                }
            }
        }
    }

    private func row(for model: LocalModelDescriptor, onboarding: Bool = false) -> some View {
        let state = state(for: model)
        return VStack(alignment: .leading, spacing: VocaMetrics.related + 2) {
            VocaStatusLine(
                status: state.status,
                title: model.displayName,
                detail: onboarding
                    ? "\(model.sizeLabel) · \(model.languages)"
                    : detail(for: model, state: state)
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
                    // A bare percentage on a 670 MB download reads as stuck.
                    // The size says how much is actually moving, and the
                    // estimate stays absent until it has settled rather than
                    // swinging wildly through the first seconds.
                    if let detail = downloadDetailLine {
                        Text(detail)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") {
                        manager.cancelDownload()
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
                Button {
                    onboarding ? downloadAndUse(model) : download(model)
                } label: {
                    Text("Download again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            case .notDownloaded:
                Button {
                    onboarding ? downloadAndUse(model) : download(model)
                } label: {
                    Text(
                        onboarding
                            ? "Download and continue · \(model.sizeLabel)"
                            : "Download \(model.sizeLabel)"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isBusy)
            case .ready:
                VocaPrimaryButton(title: "Use this model") {
                    prepare(model, languageOverride: onboarding ? guidanceLanguageOverride : nil)
                }
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
            // The role, not a bare "recommended": four models cannot all be the
            // recommendation, and which question each one answers is the thing
            // worth saying.
            if let role = role(of: model) {
                detail += " · \(role.label.lowercased())"
            }
            return detail
        }
    }

    private func download(_ model: LocalModelDescriptor) {
        manager.startDownload(model) {
            onChange()
        }
    }

    private func downloadAndUse(_ model: LocalModelDescriptor) {
        manager.startDownload(model) {
            guard manager.isDownloaded(model.id) else {
                onChange()
                return
            }
            prepare(model, languageOverride: onboarding ? guidanceLanguageOverride : nil)
        }
    }

    private func prepare(_ model: LocalModelDescriptor, languageOverride: String? = nil) {
        modelLoadError = nil
        modelLoadTask?.cancel()
        modelLoadTask = Task { @MainActor in
            do {
                let requestedLanguage = languageOverride.flatMap(TranscriptionLanguage.init(rawValue:))
                    ?? KeyboardPreferences.transcriptionLanguage
                let language = ModelLanguageSupport.resolve(
                    requestedLanguage,
                    modelLanguages: model.selectableLanguageCodes
                )
                try await manager.prepare(
                    model,
                    language: language.rawValue
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

    private func applyGuidance(language: String, priority: ModelGuidancePriority) {
        guidanceLanguageOverride = language
        guidancePriority = priority
        if let language = TranscriptionLanguage(rawValue: language) {
            KeyboardPreferences.transcriptionLanguage = language
        }
    }
}

/// Owns the sheet from one stable view. `LocalModelPicker` emits several
/// sibling `Section`s into its parent `List`; attaching a presentation modifier
/// to that multi-view builder creates multiple transient sheet presenters and
/// can pop onboarding back to its root instead of presenting the choices.
private struct ModelGuidanceChoiceButton: View {
    @Binding var selection: ModelGuidancePriority
    let language: String
    let deviceLanguageName: String
    let enabled: Bool
    let onApply: (String, ModelGuidancePriority) -> Void
    @State private var isPresented = false

    var body: some View {
        Button("Help me choose") {
            isPresented = true
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .disabled(!enabled)
        .sheet(isPresented: $isPresented) {
            ModelGuidanceChoiceSheet(
                selected: selection,
                selectedLanguage: language,
                deviceLanguageName: deviceLanguageName,
                onApply: onApply
            )
        }
    }
}

private struct ModelGuidanceChoiceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selected: ModelGuidancePriority
    let selectedLanguage: String
    let deviceLanguageName: String
    let onApply: (String, ModelGuidancePriority) -> Void

    @State private var languageSelection: String
    @State private var prioritySelection: ModelGuidancePriority

    init(
        selected: ModelGuidancePriority,
        selectedLanguage: String,
        deviceLanguageName: String,
        onApply: @escaping (String, ModelGuidancePriority) -> Void
    ) {
        self.selected = selected
        self.selectedLanguage = selectedLanguage
        self.deviceLanguageName = deviceLanguageName
        self.onApply = onApply
        _languageSelection = State(initialValue: selectedLanguage)
        _prioritySelection = State(initialValue: selected)
    }

    private var languageOptions: [(code: String, name: String)] {
        var options: [(code: String, name: String)] = [
            (
                TranscriptionLanguage.automatic.rawValue,
                "Use iPhone language (\(deviceLanguageName))"
            )
        ]
        options += TranscriptionLanguage.allCases
            .filter { $0 != .automatic }
            .map { ($0.rawValue, $0.displayName) }
        if !options.contains(where: { $0.code == selectedLanguage }),
           let name = Locale.current.localizedString(forLanguageCode: selectedLanguage) {
            options.insert((selectedLanguage, name), at: 1)
        }
        return options
    }

    /// What the current answers would actually produce, recomputed as they
    /// change. Two abstract questions with no visible consequence is what made
    /// this sheet hard to answer; the preview is the answer to both.
    private var preview: ModelGuidanceResult {
        LocalModelCatalog.guidance(
            deviceMemoryGB: LocalModelCatalog.deviceMemoryGB,
            intent: ModelGuidanceIntent(
                language: languageSelection,
                priority: prioritySelection
            )
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        "Tell us the language you speak most and what matters most "
                            + "for the download. The match below updates as you choose."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Section("What language do you speak most?") {
                    Picker("Primary language", selection: $languageSelection) {
                        ForEach(languageOptions, id: \.code) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                }

                Section("What matters most?") {
                    ForEach(ModelGuidancePriority.allCases) { priority in
                        Button {
                            prioritySelection = priority
                        } label: {
                            HStack(alignment: .top, spacing: VocaMetrics.related + 2) {
                                Image(
                                    systemName: priority == prioritySelection
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                                .foregroundStyle(
                                    priority == prioritySelection ? Color.brand : .secondary
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(priority.title)
                                        .font(.headline)
                                    Text(priority.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            priority == prioritySelection ? [.isSelected] : []
                        )
                    }
                }

                Section("You would get") {
                    if let model = preview.model {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.displayName)
                                .font(.headline)
                            Text(preview.downloadDetail ?? model.sizeLabel)
                                .font(.subheadline)
                            Text(preview.reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(preview.reason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Help me choose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this match") {
                        onApply(languageSelection, prioritySelection)
                        dismiss()
                    }
                    .disabled(preview.model == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#if DEBUG

// MARK: - Previews

// Seven row states, three of which cannot be reached on purpose: verifying
// lasts seconds, loading needs a real ONNX graph, and failed integrity needs a
// corrupted download. All three have their own wording, and none of it had ever
// been looked at.

/// A `List` because the picker builds `Section`s, which have no meaning outside
/// one.
private struct ModelPickerPreview: View {
    let manager: LocalModelManager
    var selected: String?

    var body: some View {
        NavigationStack {
            List {
                LocalModelPicker(manager: manager, previewSelectedModelID: selected)
            }
            .navigationTitle("On-device models")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("Models — nothing downloaded") {
    PreviewHost { ModelPickerPreview(manager: LocalModelManager(preview: [])) }
}

#Preview("Models — downloading") {
    PreviewHost {
        ModelPickerPreview(
            manager: LocalModelManager(
                preview: [],
                downloading: PreviewFixtures.firstModelID,
                progress: 0.43
            )
        )
    }
}

#Preview("Models — verifying checksums") {
    PreviewHost {
        ModelPickerPreview(
            manager: LocalModelManager(
                preview: [],
                verifying: [PreviewFixtures.firstModelID]
            )
        )
    }
}

#Preview("Models — failed verification") {
    PreviewHost {
        ModelPickerPreview(
            manager: LocalModelManager(
                preview: [],
                failedIntegrity: [PreviewFixtures.firstModelID],
                message: "The downloaded files do not match their published checksums.",
                hasError: true
            )
        )
    }
}

#Preview("Models — loading the engine") {
    PreviewHost {
        ModelPickerPreview(
            manager: LocalModelManager(
                preview: [PreviewFixtures.firstModelID],
                loading: PreviewFixtures.firstModelID,
                loadingMessage: "Building the decoder for the first time…"
            )
        )
    }
}

/// One model in use, another ready beside it — and every other Download button
/// disabled by `isBusy` with nothing on screen saying why.
#Preview("Models — one in use, one downloading") {
    PreviewHost {
        ModelPickerPreview(
            manager: LocalModelManager(
                preview: [PreviewFixtures.firstModelID, PreviewFixtures.secondModelID],
                downloading: PreviewFixtures.secondModelID,
                progress: 0.12
            ),
            selected: PreviewFixtures.firstModelID
        )
    }
}

#Preview("Models — ready and in use") {
    PreviewHost {
        ModelPickerPreview(
            manager: LocalModelManager(
                preview: [PreviewFixtures.firstModelID, PreviewFixtures.secondModelID]
            ),
            selected: PreviewFixtures.firstModelID
        )
    }
}

/// The download row puts a label and a percentage at opposite ends of one line,
/// which is the finding this matrix makes visible.
#Preview("Models — matrix", traits: .sizeThatFitsLayout) {
    PreviewMatrix {
        ModelPickerPreview(
            manager: LocalModelManager(
                preview: [PreviewFixtures.firstModelID],
                downloading: PreviewFixtures.secondModelID,
                progress: 0.67
            ),
            selected: PreviewFixtures.firstModelID
        )
    }
}
#endif
