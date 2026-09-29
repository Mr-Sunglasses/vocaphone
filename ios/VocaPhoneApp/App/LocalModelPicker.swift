import SwiftUI

/// The on-device model list, shared by setup and settings.
///
/// Choosing a model is one question — which language do you speak — and the
/// answer is at most three rows named by what they trade: the most accurate
/// model for that language, a much smaller download, and one that hears more
/// languages. The best one is already picked. Family names, ratings and the
/// rest of the catalog are one tap further, under All models, for the people
/// who want them.
struct LocalModelPicker: View {
    let manager: LocalModelManager
    /// Setup needs its status line refreshed on every change; Settings does not.
    var onChange: () -> Void = {}
    /// Onboarding presents the choice as a page; Settings as list sections.
    var onboarding = false
    var guidanceLanguage = ""
    /// The whole catalog as one list: the All models page.
    var expandsAvailableModels = false
    /// Onboarding only: the row the docked button downloads or continues
    /// with. Setup owns it because the button lives outside this view.
    var selection: Binding<String?> = .constant(nil)
    /// All models inside onboarding. When set, Use there loads nothing: it
    /// hands the model back as the page's pick and closes the sheet, and the
    /// docked Continue commits and loads it like any row on the page. A load
    /// started here would finish on its own schedule and could undo whatever
    /// was picked after it. Get reports its model too, at the tap.
    var onPick: ((LocalModelDescriptor) -> Void)?

#if DEBUG
    /// Which model a `#Preview` should draw as "In use". Production leaves this
    /// nil and reads the stored preference, because a canvas must not write the
    /// developer's real model selection to reach one row state.
    var previewSelectedModelID: String?
#endif

    @State private var modelLoadTask: Task<Void, Never>?
    @State private var modelLoadError: String?
    @State private var pendingDeletion: LocalModelDescriptor?
    @State private var guidanceLanguageOverride: String?
    @State private var isShowingLanguages = false
    @State private var isShowingAllModels = false
    @Environment(\.dismiss) private var dismiss

    private var usable: [LocalModelDescriptor] { LocalModelCatalog.usableOnDevice }

    private var installedModels: [LocalModelDescriptor] {
        usable.filter { manager.isDownloaded($0.id) || state(for: $0) != .notDownloaded }
    }

    private var notInstalledModels: [LocalModelDescriptor] {
        usable.filter { state(for: $0) == .notDownloaded }
    }

    private var recommendationLanguage: String {
        recommendationLanguages.first ?? LocalModelCatalog.deviceLanguage
    }

    private var recommendationLanguages: [String] {
        Self.recommendationLanguages(
            preferred: guidanceLanguageOverride ?? guidanceLanguage
        )
    }

    /// Enabled keyboards, globe order. See `LocalModelCatalog.spokenLanguages`.
    @MainActor
    static func recommendationLanguages(preferred: String) -> [String] {
        LocalModelCatalog.spokenLanguages(
            device: LocalModelCatalog.deviceLanguage,
            keyboards: KeyboardInputLanguages.snapshot,
            explicit: preferred
        )
    }

    @MainActor
    static func recommendationLanguage(preferred: String) -> String {
        recommendationLanguages(preferred: preferred).first
            ?? LocalModelCatalog.deviceLanguage
    }

    /// The rows Choose model offers for `preferred`. Setup asks for the same
    /// list to know what its docked button acts on before this view has
    /// written a selection.
    @MainActor
    static func choices(preferred: String) -> [ModelChoice] {
        LocalModelCatalog.modelChoices(
            deviceMemoryGB: LocalModelCatalog.deviceMemoryGB,
            languages: recommendationLanguages(preferred: preferred)
        )
    }

    private var recommendationLanguageName: String {
        Self.languageName(recommendationLanguage)
    }

    static func languageName(_ code: String) -> String {
        TranscriptionLanguage(rawValue: code)?.displayName
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code.uppercased()
    }

    private var choices: [ModelChoice] {
        LocalModelCatalog.modelChoices(
            deviceMemoryGB: LocalModelCatalog.deviceMemoryGB,
            languages: recommendationLanguages
        )
    }

    /// The choices, then anything else already on this iPhone or on its way.
    /// A model started from All models has to show up here, or the page
    /// looks like nothing happened.
    private var onboardingRows: [(model: LocalModelDescriptor, kind: ModelChoice.Kind?)] {
        let listed = choices
        let ids = Set(listed.map(\.model.id))
        return listed.map { ($0.model, Optional($0.kind)) }
            + installedModels.filter { !ids.contains($0.id) }.map { ($0, nil) }
    }

    private var selectedID: String? { selection.wrappedValue }

    private var downloadWarning: DownloadWarning? {
        guard onboarding,
              let id = selectedID,
              let model = LocalModelCatalog.descriptor(for: id),
              state(for: model) == .notDownloaded
        else { return nil }
        let warning = DownloadReadiness.warning(
            sizeBytes: model.sizeBytes,
            freeBytes: manager.availableStorageBytes,
            metered: false
        )
        // Cellular "may charge for data" flickered on and off with path
        // updates. Storage is the only hard stop worth a line here.
        guard case .notEnoughStorage = warning else { return nil }
        return warning
    }

    private func warningHeadline(_ warning: DownloadWarning) -> String {
        switch warning {
        case let .notEnoughStorage(freeBytes, requiredBytes):
            "Needs \(DownloadReadiness.byteLabel(requiredBytes)) free · "
                + "\(DownloadReadiness.byteLabel(freeBytes)) available. Free up space, or pick a smaller one."
        case let .meteredConnection(sizeBytes):
            "This connection may charge for data · \(DownloadReadiness.byteLabel(sizeBytes)) download."
        }
    }

    /// The states a model can be in, named once so every surface uses the
    /// same words for them.
    private enum ModelState: Equatable {
        case notDownloaded
        case downloading
        case waiting
        case verifying
        case failedIntegrity
        case loading
        case ready
        case selected
    }

    private func state(for model: LocalModelDescriptor) -> ModelState {
        if manager.isDownloading(model.id) { return .downloading }
        if manager.isQueued(model.id) { return .waiting }
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
        } else if expandsAvailableModels {
            allModelsSections
        } else {
            settingsSections
        }
    }

    // MARK: - Words

    private func title(for model: LocalModelDescriptor, kind: ModelChoice.Kind?) -> String {
        switch kind {
        case .best: "Best for \(recommendationLanguageName)"
        case .smaller: "Smaller download"
        case .moreLanguages: "More languages"
        case nil: model.plain.title
        }
    }

    /// What the row trades, in one sentence a person can decide on.
    private func tradeOff(for model: LocalModelDescriptor, kind: ModelChoice.Kind?) -> String {
        switch kind {
        case .best:
            return "The most accurate model for \(recommendationLanguageName) on this iPhone."
        case .smaller:
            let best = choices.first?.model
            if let best, model.plain.accuracy < best.plain.accuracy {
                return "Quicker to download. Makes a few more mistakes."
            }
            return "Quicker to download, and nearly as accurate."
        case .moreLanguages:
            let count = model.languageCodes.count
            return count == 0
                ? "Understands about 100 languages, if you switch between them."
                : "Understands \(count) languages and tells them apart."
        case nil:
            return model.plain.summary
        }
    }

    /// "147 MB · Basic, most languages": one separator per line, so the
    /// name reads as one thing.
    ///
    /// The choice rows already say which one is best, so the line drops "Best"
    /// from a plain title: a "More languages" row reading "Best, most
    /// languages" under a "Best for Hindi" row claimed two bests. "Basic" and
    /// "Good" stay — they are the cue that a wider row trades accuracy away.
    private func sizeAndName(_ model: LocalModelDescriptor, kind: ModelChoice.Kind?) -> String {
        guard kind != nil else { return model.sizeLabel }
        var parts = model.plain.title.components(separatedBy: " · ")
        if parts.count > 1, Self.qualityWords.contains(parts[0]) { parts.removeFirst() }
        let name = parts.joined(separator: ", ")
        return "\(model.sizeLabel) · \(name.prefix(1).uppercased() + name.dropFirst())"
    }

    private static let qualityWords: Set<String> = ["Best"]

    private func languagesFact(for model: LocalModelDescriptor) -> String {
        if model.languageCodes.count > 2 { return "\(model.languageCodes.count) languages" }
        return model.languages.replacingOccurrences(of: " · auto-detect", with: "")
    }

    private func downloadDetailLine(for id: String) -> String {
        let percent = "\(Int(manager.progress(for: id) * 100))%"
        let parts = [percent, manager.downloadSizeProgress(for: id), manager.downloadTimeRemaining(for: id)]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// The small line under a row: what it costs, or what is happening to it.
    private func statusLine(
        for model: LocalModelDescriptor,
        kind: ModelChoice.Kind?,
        state: ModelState
    ) -> (text: String, tint: Color) {
        switch state {
        case .notDownloaded:
            (sizeAndName(model, kind: kind), Color.vocaSecondaryText)
        case .downloading where manager.isOptimizing(model.id):
            ("Optimizing for this iPhone. This happens once.", Color.vocaSecondaryText)
        case .downloading:
            ("Downloading · " + downloadDetailLine(for: model.id), Color.brand)
        case .waiting:
            ("Waiting to download", Color.vocaSecondaryText)
        case .verifying:
            ("Checking the files…", Color.vocaSecondaryText)
        case .failedIntegrity:
            ("The files did not match. Download it again.", Color.vocaError)
        case .loading:
            (manager.loadingMessage ?? "Loading…", Color.vocaSecondaryText)
        case .ready:
            ("On this iPhone · \(model.sizeLabel)", Color.brand)
        case .selected:
            ("In use · \(model.sizeLabel)", Color.brand)
        }
    }

    // MARK: - Onboarding

    @ViewBuilder
    private var onboardingBody: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.padding - VocaMetrics.tight) {
            if usable.isEmpty {
                Text("No on-device model fits this iPhone yet.")
                    .font(.subheadline)
                    .foregroundStyle(Color.vocaSecondaryText)
            } else {
                languageButton
                    .padding(.bottom, VocaMetrics.tight)
                if choices.isEmpty {
                    Text("No model that fits this iPhone understands \(recommendationLanguageName) yet. Pick another language, or skip for now.")
                        .font(.subheadline)
                        .foregroundStyle(Color.vocaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !onboardingRows.isEmpty {
                    onboardingChoiceList
                }
                allModelsButton
                onboardingNotes
            }
        }
        .onAppear {
            KeyboardInputLanguages.refresh()
            reconcileSelection()
        }
        .onChange(of: onboardingRows.map(\.model.id)) { _, _ in reconcileSelection() }
        .sheet(isPresented: $isShowingLanguages) { languageSheet }
        .sheet(isPresented: $isShowingAllModels) {
            NavigationStack {
                List {
                    LocalModelPicker(
                        manager: manager,
                        onChange: onChange,
                        guidanceLanguage: guidanceLanguageOverride ?? guidanceLanguage,
                        expandsAvailableModels: true,
                        onPick: { selection.wrappedValue = $0.id }
                    )
                }
                .navigationTitle("All models")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isShowingAllModels = false }
                    }
                }
            }
        }
        // Leaving Choose model ends this page's claim on the selection. The
        // download itself lives on the manager and carries on.
        .onDisappear {
            modelLoadTask?.cancel()
            modelLoadTask = nil
        }
    }

    /// Keeps the docked button pointed at a row that is on the page. Coming
    /// back to the page, whatever is already here or on its way wins over
    /// the suggestion, so the button says Continue rather than offering a
    /// second download.
    private func reconcileSelection() {
        let rows = onboardingRows.map(\.model)
        if let current = selectedID, rows.contains(where: { $0.id == current }) { return }
        let inUse = rows.first { $0.id == LocalTranscriptionPreferences.modelIdentifier && manager.isDownloaded($0.id) }
        let arriving = rows.first { manager.isDownloading($0.id) || manager.isQueued($0.id) }
        let downloaded = rows.first { manager.isDownloaded($0.id) && !manager.failedIntegrityModelIDs.contains($0.id) }
        selection.wrappedValue = (inUse ?? arriving ?? downloaded ?? rows.first)?.id
    }

    /// The one question. A menu of sixty languages was a list to scroll with
    /// nothing to type into; this opens a searchable one.
    private var languageButton: some View {
        Button {
            isShowingLanguages = true
        } label: {
            HStack(spacing: VocaMetrics.padding - VocaMetrics.tight) {
                Image(systemName: "globe")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.brand)
                    .accessibilityHidden(true)
                Text("I speak")
                    .font(.body)
                    .foregroundStyle(Color.vocaSecondaryText)
                Spacer(minLength: VocaMetrics.related)
                Text(recommendationLanguageName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.vocaPrimaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.vocaSecondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, VocaMetrics.padding + 2)
            .frame(maxWidth: .infinity, minHeight: VocaMetrics.minimumTarget + VocaMetrics.padding)
            .background(
                Color.vocaSurface,
                in: RoundedRectangle(cornerRadius: VocaMetrics.cardRadius + 2, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: VocaMetrics.cardRadius + 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Language you speak")
        .accessibilityValue(recommendationLanguageName)
        .accessibilityHint("Changes which models are suggested")
    }

    private var languageSheet: some View {
        LanguageChoiceSheet(
            selected: recommendationLanguage,
            suggested: Self.recommendationLanguages(preferred: "")
        ) { code in
            guidanceLanguageOverride = code
            // First run has no dictation language yet, so the answer
            // becomes it. In Settings that switch has its own row, and
            // asking for suggestions must not quietly change it.
            if onboarding, let language = TranscriptionLanguage(rawValue: code) {
                KeyboardPreferences.transcriptionLanguage = language
            }
            if onboarding {
                // A new language is a new question: its best answer is the
                // one to offer, not whatever was picked for the last one —
                // unless a download already on its way hears that language.
                // An English model mid-download is no answer for Croatian.
                let best = Self.choices(preferred: code).first?.model
                let arriving = installedModels.first {
                    (manager.isDownloading($0.id) || manager.isQueued($0.id)) && $0.covers(code)
                }
                selection.wrappedValue = (arriving ?? best)?.id
            }
        }
    }

    /// Radio rows in one card: pick one, and the docked button does the rest.
    private var onboardingChoiceList: some View {
        let rows = onboardingRows
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.model.id) { index, row in
                if index > 0 {
                    Divider()
                        .padding(.leading, VocaMetrics.padding + 2 + 28 + VocaMetrics.padding - VocaMetrics.tight)
                }
                onboardingChoiceRow(row.model, kind: row.kind)
            }
        }
        .background(
            Color.vocaSurface,
            in: RoundedRectangle(cornerRadius: VocaMetrics.heroRadius - 2, style: .continuous)
        )
        .animation(.snappy(duration: 0.25), value: rows.map(\.model.id))
    }

    private func onboardingChoiceRow(_ model: LocalModelDescriptor, kind: ModelChoice.Kind?) -> some View {
        let state = state(for: model)
        let isSelected = selectedID == model.id
        let status = statusLine(for: model, kind: kind, state: state)
        return HStack(alignment: .center, spacing: VocaMetrics.padding - VocaMetrics.tight) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { selection.wrappedValue = model.id }
            } label: {
                HStack(alignment: .top, spacing: VocaMetrics.padding - VocaMetrics.tight) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(isSelected ? Color.brand : Color.vocaSecondaryText.opacity(0.6))
                        .frame(width: 28)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        titleLine(title(for: model, kind: kind), badged: kind == .best, font: .headline)
                        Text(tradeOff(for: model, kind: kind))
                            .font(.subheadline)
                            .foregroundStyle(Color.vocaSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(status.text)
                            .font(.footnote.weight(.medium).monospacedDigit())
                            .foregroundStyle(status.tint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityHint("Selects this model")

            // A transfer can be stopped from its row; nothing else needs a
            // second control, because the docked button acts on the selection.
            if state == .downloading || state == .waiting {
                stopDownloadButton(model)
            } else if state == .verifying || state == .loading {
                ProgressView()
                    .frame(width: VocaMetrics.minimumTarget, height: VocaMetrics.minimumTarget)
            }
        }
        .padding(.vertical, VocaMetrics.padding - 2)
        .padding(.leading, VocaMetrics.padding + 2)
        .padding(.trailing, VocaMetrics.padding - VocaMetrics.tight)
    }

    /// The title with Recommended beside it, or under it once the two no
    /// longer fit on one line — a long language name at a large text size.
    @ViewBuilder
    private func titleLine(_ text: String, badged: Bool, font: Font) -> some View {
        let title = Text(text)
            .font(font)
            .foregroundStyle(Color.vocaPrimaryText)
        if badged {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VocaMetrics.related) {
                    title.fixedSize()
                    recommendedBadge
                }
                VStack(alignment: .leading, spacing: VocaMetrics.tight) {
                    title.fixedSize(horizontal: false, vertical: true)
                    recommendedBadge
                }
            }
        } else {
            title.fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recommendedBadge: some View {
        Text("Recommended")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.brand)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.brand.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    @ViewBuilder
    private func stopDownloadButton(_ model: LocalModelDescriptor) -> some View {
        if manager.isOptimizing(model.id) {
            // Every byte is in and the compile cannot be stopped.
            ProgressView()
                .frame(width: VocaMetrics.minimumTarget, height: VocaMetrics.minimumTarget)
        } else {
            Button {
                manager.cancelDownload(model.id)
                onChange()
            } label: {
                DownloadProgressRing(
                    fraction: state(for: model) == .waiting ? 0 : manager.progress(for: model.id)
                )
                .frame(width: VocaMetrics.minimumTarget, height: VocaMetrics.minimumTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop downloading")
            .accessibilityValue("\(Int(manager.progress(for: model.id) * 100)) percent")
        }
    }

    private var allModelsButton: some View {
        Button {
            isShowingAllModels = true
        } label: {
            HStack(spacing: VocaMetrics.tight) {
                Text("See all \(usable.count) models")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.brand)
            .frame(minHeight: VocaMetrics.minimumTarget)
            .padding(.horizontal, VocaMetrics.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows every model that runs on this iPhone")
    }

    @ViewBuilder
    private var onboardingNotes: some View {
        if let warning = downloadWarning {
            Text(warningHeadline(warning))
                .font(.footnote)
                .foregroundStyle(Color.vocaError)
                .fixedSize(horizontal: false, vertical: true)
        } else if let id = selectedID,
                  let model = LocalModelCatalog.descriptor(for: id),
                  state(for: model) == .notDownloaded {
            // The docked button says Download; this says what that costs in
            // time, which is nothing: setup carries on while it arrives.
            // One sentence: the page's own subtitle already says a model can be
            // switched later, and a second line ran under the docked button.
            Text("It downloads while you finish setting up.")
                .font(.footnote)
                .foregroundStyle(Color.vocaSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let modelLoadError {
            Text(modelLoadError)
                .font(.footnote)
                .foregroundStyle(Color.vocaError)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let message = manager.message, manager.hasError {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.vocaError)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Settings

    /// The model the retired-model migration moved this iPhone onto, while it
    /// still has to be downloaded. See `retiredModelSection`.
    private var retiredModelReplacement: LocalModelDescriptor? {
        guard LocalTranscriptionPreferences.selectionIsRetiredModelReplacement,
              let model = LocalModelCatalog.descriptor(for: LocalTranscriptionPreferences.modelIdentifier),
              state(for: model) == .notDownloaded || state(for: model) == .failedIntegrity
        else { return nil }
        return model
    }

    /// The other half of the retired-model migration.
    ///
    /// Launch moves a stored selection onto its nearest surviving model but
    /// cannot download it — that is hundreds of megabytes nobody agreed to — so
    /// until it is here, a dictation stops before recording and says a voice
    /// model is needed. This section is what that message points at: why the
    /// model changed, what it will cost, and the one button that fixes it.
    @ViewBuilder
    private var retiredModelSection: some View {
        if let model = retiredModelReplacement {
            Section {
                VStack(alignment: .leading, spacing: VocaMetrics.related) {
                    Text("Your voice model was updated")
                        .font(.headline)
                    Text(
                        "The model you were using is no longer offered. Its closest "
                            + "replacement is “\(model.plain.title)”: \(model.plain.summary) "
                            + "Download it to keep dictating on this iPhone."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Download \(model.sizeLabel)") {
                        downloadAndUse(model)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!manager.downloadingModelIDs.isEmpty)
                }
                .padding(.vertical, VocaMetrics.tight)
            }
        }
    }

    /// What is on this iPhone, then the same three suggestions as first run,
    /// then the door to everything else. Tap to use, Get to download, swipe
    /// to delete — the gestures every iPhone list already teaches.
    @ViewBuilder
    private var settingsSections: some View {
        Group {
            retiredModelSection

            if !installedModels.isEmpty {
                Section {
                    ForEach(installedModels) { model in
                        compactRow(model, kind: nil, detailed: false)
                    }
                } header: {
                    Text("On this iPhone")
                } footer: {
                    Text("Tap a model to use it. Swipe left to delete one.")
                }
            }

            Section {
                Button {
                    isShowingLanguages = true
                } label: {
                    LabeledContent("Suggest for") {
                        HStack(spacing: VocaMetrics.tight) {
                            Text(recommendationLanguageName)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Changes which models are suggested")
                // On the row, not the section: one stable presenter.
                .sheet(isPresented: $isShowingLanguages) { languageSheet }

                let suggestions = choices.filter { state(for: $0.model) == .notDownloaded }
                if choices.isEmpty {
                    Text("No model that fits this iPhone understands \(recommendationLanguageName) yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if suggestions.isEmpty {
                    Text("The suggestions for \(recommendationLanguageName) are already on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestions) { choice in
                        compactRow(choice.model, kind: choice.kind, detailed: false)
                    }
                }

                NavigationLink {
                    List {
                        LocalModelPicker(
                            manager: manager,
                            onChange: onChange,
                            guidanceLanguage: guidanceLanguageOverride ?? guidanceLanguage,
                            expandsAvailableModels: true
                        )
                    }
                    .navigationTitle("All models")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent("All models", value: "\(usable.count)")
                }
            } header: {
                Text("Get a model")
            } footer: {
                Text("Every model runs offline on this iPhone. Your current model stays in use until you pick another.")
            }

            if manager.message != nil || modelLoadError != nil {
                messageSection
            }
        }
    }

    /// Everything this iPhone can run, with the details the short list
    /// leaves out: who made it, how it rates, and its upstream name.
    @ViewBuilder
    private var allModelsSections: some View {
        retiredModelSection
        if !installedModels.isEmpty {
            Section("On this iPhone") {
                ForEach(installedModels) { model in
                    compactRow(model, kind: nil, detailed: true)
                }
            }
        }
        if !notInstalledModels.isEmpty {
            Section {
                ForEach(notInstalledModels) { model in
                    compactRow(model, kind: nil, detailed: true)
                }
            } header: {
                Text("Available to download")
            } footer: {
                Text("Every model here runs on this iPhone. You can switch models any time in Settings.")
            }
        }
        if manager.message != nil || modelLoadError != nil {
            messageSection
        }
    }

    private var messageSection: some View {
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

    /// One list row: name, one line of state, and the single action it
    /// offers at the trailing edge. A ready row is itself the Use button.
    @ViewBuilder
    private func compactRow(
        _ model: LocalModelDescriptor,
        kind: ModelChoice.Kind?,
        detailed: Bool
    ) -> some View {
        let state = state(for: model)
        let isOnDisk = state == .ready || state == .selected || state == .failedIntegrity
        Group {
            if state == .ready {
                Button {
                    use(model)
                } label: {
                    compactRowContent(model, kind: kind, detailed: detailed, state: state)
                }
                .buttonStyle(.plain)
                .disabled(manager.loadingModelID != nil)
                .accessibilityHint("Uses this model for dictation")
            } else {
                compactRowContent(model, kind: kind, detailed: detailed, state: state)
            }
        }
        .swipeActions(edge: .trailing) {
            if isOnDisk {
                Button(role: .destructive) {
                    pendingDeletion = model
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if state == .ready {
                Button {
                    use(model)
                } label: {
                    Label("Use this model", systemImage: "checkmark.circle")
                }
            }
            if isOnDisk {
                Button(role: .destructive) {
                    pendingDeletion = model
                } label: {
                    Label("Delete \(model.sizeLabel)", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.plain.title ?? "this model")?",
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

    private func compactRowContent(
        _ model: LocalModelDescriptor,
        kind: ModelChoice.Kind?,
        detailed: Bool,
        state: ModelState
    ) -> some View {
        let status = detailed || kind == nil
            ? detailedStatus(for: model, state: state)
            : statusLine(for: model, kind: kind, state: state)
        return HStack(alignment: .center, spacing: VocaMetrics.padding - VocaMetrics.tight) {
            if detailed {
                ModelMakerTile(maker: model.maker, size: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                titleLine(title(for: model, kind: kind), badged: kind == .best, font: .body.weight(.semibold))
                if detailed {
                    Text(model.plain.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ModelRatingsView(plain: model.plain)
                    Text(model.technicalName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(status.text)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(status.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            rowAccessory(model, state: state)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Settings rows name their size and coverage rather than a trade-off:
    /// there is no "best" to compare against in a list of what is installed.
    private func detailedStatus(
        for model: LocalModelDescriptor,
        state: ModelState
    ) -> (text: String, tint: Color) {
        switch state {
        case .notDownloaded, .ready:
            ("\(model.sizeLabel) · \(languagesFact(for: model))", Color.vocaSecondaryText)
        default:
            statusLine(for: model, kind: nil, state: state)
        }
    }

    @ViewBuilder
    private func rowAccessory(_ model: LocalModelDescriptor, state: ModelState) -> some View {
        switch state {
        case .notDownloaded:
            Button {
                downloadAndUse(model)
            } label: {
                Text("Get")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 56, minHeight: 30)
                    .background(Color.brand, in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download \(model.plain.title), \(model.sizeLabel)")
        case .failedIntegrity:
            Button {
                downloadAndUse(model)
            } label: {
                Text("Retry")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.brand)
                    .frame(minWidth: 56, minHeight: 30)
                    .background(Color.brand.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.borderless)
        case .downloading, .waiting:
            stopDownloadButton(model)
        case .verifying, .loading:
            ProgressView()
        case .ready:
            Text("Use")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brand)
                .accessibilityHidden(true)
        case .selected:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.brand)
                .accessibilityLabel("In use")
        }
    }

    // MARK: - Actions

    /// A tap on a ready row: load it and use it — or, inside onboarding, hand
    /// it back as the page's pick. See `onPick`.
    private func use(_ model: LocalModelDescriptor) {
        if let onPick {
            onPick(model)
            dismiss()
        } else {
            prepare(model)
        }
    }

    /// Downloads, and makes the model the one in use only if nothing usable is
    /// selected yet. Used from Settings as well as setup: a phone with no model
    /// that finishes downloading one should be able to dictate with it, not
    /// keep saying "No speech-to-text model downloaded" until someone finds
    /// Use. With a model already chosen it changes nothing.
    private func downloadAndUse(_ model: LocalModelDescriptor) {
        onPick?(model)
        manager.startDownload(model) {
            guard manager.isDownloaded(model.id) else {
                onChange()
                return
            }
            let inUse = LocalTranscriptionPreferences.modelIdentifier
            if let inUse, manager.isDownloaded(inUse) {
                onChange()
                return
            }
            prepare(
                model,
                languageOverride: onboarding ? guidanceLanguageOverride : nil,
                adoptsOnlyIfUnclaimed: true
            )
        }
        onChange()
    }

    /// Loads the engine and, on success, records the model as the one in use.
    ///
    /// `adoptsOnlyIfUnclaimed` is for the callers that are adopting a finished
    /// download rather than obeying a tap. Loading takes seconds, and
    /// onboarding's Continue can commit a different model inside that window;
    /// without the re-check the stored identifier ends up naming whichever
    /// engine happened to finish second, which is not what anyone chose.
    private func prepare(
        _ model: LocalModelDescriptor,
        languageOverride: String? = nil,
        adoptsOnlyIfUnclaimed: Bool = false
    ) {
        modelLoadError = nil
        modelLoadTask?.cancel()
        // A finished download is adopted the moment its files are on disk,
        // before the engine is loaded — which is how the rest of the app
        // already defines ready (`isOnDeviceReady` is "downloaded", not
        // "loaded"), and what Continue and a resumed download both do.
        //
        // Committed synchronously, not inside the task: a task starts on a
        // later turn, and home would still get one frame of the wrong card.
        if adoptsOnlyIfUnclaimed {
            if let inUse = LocalTranscriptionPreferences.modelIdentifier,
               inUse != model.id,
               manager.isDownloaded(inUse),
               !manager.failedIntegrityModelIDs.contains(inUse)
            {
                // Something else is the model. Nothing to adopt, and no reason
                // to load an engine nobody chose.
                return
            }
            commitSelection(model)
        }
        let commitsAfterLoad = !adoptsOnlyIfUnclaimed
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
                // Use is a choice the user is watching happen: it commits only
                // once the engine has actually loaded, so a failed load does
                // not quietly switch their model.
                if commitsAfterLoad { commitSelection(model) }
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

    private func commitSelection(_ model: LocalModelDescriptor) {
        LocalTranscriptionPreferences.modelIdentifier = model.id
        LocalTranscriptionPreferences.enabled = true
        onChange()
    }
}

/// Every language the models know, searchable, with the ones this iPhone
/// already types listed first.
///
/// The list is built once when the sheet opens. A `Menu` picker rebuilt its
/// sixty rows on every redraw of the page behind it, and each rebuild threw
/// the scroll position back to the top while someone was still scrolling.
private struct LanguageChoiceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selected: String
    let onPick: (String) -> Void

    private let suggested: [Option]
    private let all: [Option]
    @State private var query = ""

    struct Option: Identifiable, Equatable {
        let code: String
        let name: String
        /// The language's name for itself, when that differs: "Hrvatski".
        let endonym: String?
        var id: String { code }
    }

    init(selected: String, suggested: [String], onPick: @escaping (String) -> Void) {
        self.selected = selected
        self.onPick = onPick
        func option(_ code: String) -> Option {
            let name = LocalModelPicker.languageName(code)
            let own = Locale(identifier: code).localizedString(forLanguageCode: code)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return Option(code: code, name: name, endonym: own == name ? nil : own)
        }
        let codes = TranscriptionLanguage.allCases
            .filter { $0 != .automatic }
            .map(\.rawValue)
        self.suggested = suggested.filter(codes.contains).map(option)
        self.all = codes.map(option).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var matches: [Option] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.name.localizedStandardContains(needle)
                || ($0.endonym?.localizedStandardContains(needle) ?? false)
                || $0.code.caseInsensitiveCompare(needle) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty, !suggested.isEmpty {
                    Section("On your keyboards") {
                        ForEach(suggested) { row($0) }
                    }
                }
                Section(query.isEmpty ? "All languages" : "") {
                    ForEach(matches) { row($0) }
                }
            }
            .overlay {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search languages"
            )
            .navigationTitle("Language you speak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func row(_ option: Option) -> some View {
        Button {
            onPick(option.code)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name)
                        .foregroundStyle(Color.vocaPrimaryText)
                    if let endonym = option.endonym {
                        Text(endonym)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if option.code == selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.brand)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(option.code == selected ? [.isSelected] : [])
    }
}

/// App Store's download control: a ring that fills clockwise from 12 o'clock
/// with a stop square in the middle, because tapping it stops the transfer.
private struct DownloadProgressRing: View {
    var fraction: Double
    var diameter: CGFloat = 28
    var lineWidth: CGFloat = 3

    var body: some View {
        let clamped = min(1, max(0, fraction))
        ZStack {
            Circle()
                .stroke(Color.brand.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped == 0 ? 0 : max(0.03, clamped))
                .stroke(Color.brand, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: clamped)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.brand)
                .frame(width: diameter * 0.3, height: diameter * 0.3)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// A model's maker, as a small brand-coloured tile. Makers with a published
/// glyph (Simple Icons, CC0) show it; the rest show their initials.
/// Accuracy and speed as four dots each: two answers a person can compare at
/// a glance without knowing what a word error rate is. See
/// `ModelPlainLanguage` for where the numbers come from.
struct ModelRatingsView: View {
    let plain: ModelPlainLanguage

    var body: some View {
        HStack(spacing: VocaMetrics.padding - VocaMetrics.tight) {
            rating("Accuracy", plain.accuracy)
            rating("Speed", plain.speed)
        }
        .font(.caption)
        .foregroundStyle(Color.vocaSecondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plain.accessibilityRatings)
    }

    private func rating(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
            HStack(spacing: 2) {
                ForEach(1...ModelPlainLanguage.maximumRating, id: \.self) { step in
                    Circle()
                        .fill(step <= value ? Color.brand : Color.vocaSecondaryText.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

struct ModelMakerTile: View {
    let maker: ModelMaker
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(tileColor)
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            if let glyph {
                Image(glyph)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(glyphColor)
                    .padding(size * 0.22)
            } else {
                Text(monogram)
                    .font(.system(size: size * (monogram.count > 1 ? 0.32 : 0.42), weight: .bold, design: .rounded))
                    .foregroundStyle(glyphColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Made by \(maker.displayName)")
    }

    private var glyph: String? {
        switch maker {
        case .nvidia: "MakerNVIDIA"
        case .openAI: "MakerOpenAI"
        case .huggingFace: "MakerHuggingFace"
        case .alibaba: "MakerAlibaba"
        case .usefulSensors, .sber, .meta, .nextGenKaldi: nil
        }
    }

    private var monogram: String {
        switch maker {
        case .usefulSensors: "US"
        case .sber: "S"
        case .meta: "M"
        case .nextGenKaldi: "K2"
        default: ""
        }
    }

    private var tileColor: Color {
        switch maker {
        case .nvidia: Color(red: 118 / 255, green: 185 / 255, blue: 0)
        case .openAI: Color(white: 0.12)
        case .huggingFace: Color(red: 1, green: 210 / 255, blue: 30 / 255)
        case .alibaba: Color(red: 1, green: 106 / 255, blue: 0)
        case .usefulSensors: Color(red: 91 / 255, green: 79 / 255, blue: 219 / 255)
        case .sber: Color(red: 33 / 255, green: 160 / 255, blue: 56 / 255)
        case .meta: Color(red: 8 / 255, green: 102 / 255, blue: 255 / 255)
        case .nextGenKaldi: Color(red: 196 / 255, green: 60 / 255, blue: 44 / 255)
        }
    }

    private var glyphColor: Color {
        maker == .huggingFace ? Color.black : Color.white
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

/// One model in use, another downloading. Other Gets stay available.
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
