import GRDB
import SwiftUI
import SightsAndSoundsKit

/// Import in four steps — Source › Scan › Review & Stage › Import.
///
/// Adding a source used to import everything under it in one pass: the
/// file list was never shown, and there is no un-import. Now scanning
/// produces a *list*, nothing enters the library until the list is
/// confirmed, and the tag staging boxes come along so tagging is not a
/// second trip through the grid.
struct ImportView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(AppModel.self) private var app

    enum Step: Int, CaseIterable {
        case source, scan, review, importing

        var title: String {
            switch self {
            case .source: "Source"
            case .scan: "Scan"
            case .review: "Review & Stage"
            case .importing: "Import"
            }
        }
    }

    @State private var step: Step = .source
    @State private var selectedSource: Source?
    @State private var outcome: ScanOutcome?
    @State private var scanError: String?
    @State private var scanTask: Task<Void, Never>?

    // Review state
    @State private var checkedFolders: Set<String> = []
    @State private var focusedFolder: String?
    @State private var selectedPaths: Set<String> = []
    @State private var statusFilter: StatusFilter = .newOnly
    @State private var nameFilter = ""
    @State private var probes: [String: ProbeResult] = [:]

    // Staging
    @State private var boxes: [ImportBox] = []
    @State private var perFolderScope = false
    @State private var wholeStaging = StagingDraft()
    @State private var folderStaging: [String: StagingDraft] = [:]
    @State private var showConfigure = false

    // Running
    @State private var running: JobRecord?
    @State private var progress: (current: Int, total: Int)?
    @State private var finished: String?

    // Source step data (carried over unchanged)
    @State private var itemCounts: [UUID: Int] = [:]
    @State private var online: [UUID: Bool] = [:]
    @State private var history: [JobRecord] = []
    @State private var videoExtensions: [String] = []
    @State private var audioExtensions: [String] = []
    @State private var hasOverride = false
    @State private var loadGeneration = 0

    enum StatusFilter: String, CaseIterable {
        case newOnly, all, alreadyImported

        var title: String {
            switch self {
            case .newOnly: "New only"
            case .all: "All"
            case .alreadyImported: "Already imported"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StepStrip(step: step, scanPath: selectedSource?.rootPath)
            switch step {
            case .source: sourceStep
            case .scan: scanStep
            case .review, .importing: reviewStep
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.Surface.content)
        .task { await reload() }
        .onChange(of: model.sources) { Task { await reload() } }
        .sheet(isPresented: $showConfigure) {
            ConfigureBoxesSheet(
                boxes: $boxes,
                categories: model.vocabulary.map(\.category),
                fields: (try? model.library.fields(scope: .mediaItem)) ?? [],
                onSave: { saved in
                    try? model.library.setImportBoxes(saved)
                })
        }
        .sheet(item: Binding(
            get: { finished.map { FinishedSummary(text: $0) } },
            set: { if $0 == nil { finished = nil } })
        ) { summary in
            FinishedSheet(
                summary: summary.text,
                onMore: {
                    finished = nil
                    step = .source
                },
                onOpen: {
                    finished = nil
                    model.refreshAll()
                })
        }
    }

    // MARK: - Step 1 · Source

    private var sourceStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Sources").modifier(Theme.sectionLabel())
                    if model.sources.isEmpty {
                        Text("No sources yet — add a folder to import from.")
                            .font(Theme.ui(12.5))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                    ForEach(model.sources) { source in
                        ImportSourceRow(
                            source: source,
                            itemCount: itemCounts[source.id],
                            isOnline: online[source.id],
                            onScan: { beginScan(source) })
                    }
                    HStack {
                        Button("Add Folder…") { addFolder() }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                            .help("Register a folder as a source and scan it — nothing is imported until you review the list")
                        Spacer()
                    }
                    Text("Scans are additive: new files are imported, known files are skipped, and files missing from disk are never removed.")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.disabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("File types").modifier(Theme.sectionLabel())
                    extensionRow(label: "Video", extensions: videoExtensions)
                    extensionRow(label: "Audio", extensions: audioExtensions)
                    Text(hasOverride
                        ? "This library overrides the app-wide lists — edit in Settings › Library Import."
                        : "App-wide lists — edit in Settings › Import, or override per library in Settings › Library Import.")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.disabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Recent imports").modifier(Theme.sectionLabel())
                    if history.isEmpty {
                        Text("No imports recorded yet.")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                    ForEach(history) { record in
                        ImportHistoryRow(record: record)
                    }
                }
            }
            .padding(16)
        }
    }

    private func extensionRow(label: String, extensions: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Text.tertiary)
                .frame(width: 46, alignment: .leading)
            Text(extensions.isEmpty ? "none" : extensions.joined(separator: ", "))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.quaternary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Step 2 · Scan

    private var scanStep: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning \(selectedSource?.name ?? "")…")
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.Text.tertiary)
            if let scanError {
                Text(scanError)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Status.red)
            }
            Button("Cancel") {
                scanTask?.cancel()
                step = .source
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Step 3 · Review & Stage

    private var reviewStep: some View {
        VStack(spacing: 0) {
            reviewToolbar
            HStack(spacing: 0) {
                scopeRail
                Rectangle().fill(Theme.Border.standard).frame(width: 1)
                fileTable
                Rectangle().fill(Theme.Border.standard).frame(width: 1)
                stageRail
            }
            footer
        }
        .overlay {
            if step == .importing { runningOverlay }
        }
    }

    private var reviewToolbar: some View {
        HStack(spacing: 9) {
            if let source = selectedSource {
                HStack(spacing: 6) {
                    Circle()
                        .fill(online[source.id] == false ? Theme.Status.orange : Theme.Status.green)
                        .frame(width: 7, height: 7)
                    Text(source.name)
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.Text.primary)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.iconTile))
                Button("Rescan") { beginScan(source) }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            ThemeSegmentedControl(
                selection: $statusFilter,
                options: StatusFilter.allCases.map { ($0, $0.title) },
                emphasis: .neutral)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.Text.disabled)
                TextField("Filter by name", text: $nameFilter)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .frame(width: 200)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Surface.well)
                    .stroke(Theme.Border.standard, lineWidth: 1))
            Spacer()
            Button("Configure boxes…") { showConfigure = true }
                .buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var scopeRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scan scope").modifier(Theme.sectionLabel())
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(folders, id: \.path) { folder in
                        folderRow(folder)
                    }
                }
            }
            if let outcome, !outcome.skippedByExtension.isEmpty {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Not listed").modifier(Theme.sectionLabel())
                    ForEach(outcome.skippedByExtension.sorted { $0.value > $1.value }, id: \.key) { ext, count in
                        Button {
                            enableExtension(ext)
                        } label: {
                            Text("\(count) files skipped — enable .\(ext)")
                                .font(Theme.ui(11))
                                .foregroundStyle(Theme.Status.orange)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Adds .\(ext) to this library's import override and rescans")
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 264)
        .background(Theme.Surface.raised)
    }

    private func folderRow(_ folder: (path: String, new: Int, known: Int)) -> some View {
        let checked = checkedFolders.contains(folder.path)
        let staged = folderStaging[folder.path]?.isEmpty == false
        return HStack(spacing: 8) {
            Button {
                if checked {
                    checkedFolders.remove(folder.path)
                    selectedPaths.subtract(paths(in: folder.path))
                } else {
                    checkedFolders.insert(folder.path)
                    selectedPaths.formUnion(newPaths(in: folder.path))
                }
            } label: {
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(checked ? Theme.Accent.amber : .clear)
                    .stroke(
                        checked ? Theme.Accent.amber : Theme.Border.subtleButtonHover, lineWidth: 1)
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.path.isEmpty ? "(root)" : folder.path)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(folder.new) new · \(folder.known) known")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
            }
            Spacer(minLength: 0)
            if staged {
                Circle().fill(Theme.Accent.amber).frame(width: 6, height: 6)
                    .help("This folder carries staging of its own")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(focusedFolder == folder.path ? Theme.Surface.selectedRow : .clear)
        .contentShape(Rectangle())
        .onTapGesture { focusedFolder = folder.path }
    }

    private var fileTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 34)
                Text("File").modifier(Theme.sectionLabel())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Duration").modifier(Theme.sectionLabel()).frame(width: 92, alignment: .trailing)
                Text("Size").modifier(Theme.sectionLabel()).frame(width: 76, alignment: .trailing)
                Text("Status").modifier(Theme.sectionLabel()).frame(width: 118, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .frame(height: 31)
            .background(Theme.Surface.toolbar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }

            if visibleCandidates.isEmpty {
                Text("No files match this scope and filter.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleCandidates) { candidate in
                            CandidateRow(
                                candidate: candidate,
                                probe: probes[candidate.relativePath],
                                isSelected: selectedPaths.contains(candidate.relativePath),
                                sourceRoot: selectedSource?.rootPath ?? "",
                                onToggle: {
                                    guard !candidate.isKnown else { return }
                                    if selectedPaths.contains(candidate.relativePath) {
                                        selectedPaths.remove(candidate.relativePath)
                                    } else {
                                        selectedPaths.insert(candidate.relativePath)
                                    }
                                },
                                onProbed: { result in
                                    probes[candidate.relativePath] = result
                                })
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var stageRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Stage").modifier(Theme.sectionLabel())
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            ThemeSegmentedControl(
                selection: $perFolderScope,
                options: [(false, "Whole import"), (true, "Per folder")],
                emphasis: .neutral)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Text(perFolderScope
                ? "Staging applies to the highlighted folder only. Pick a folder on the left."
                : "Staging applies to every selected file in this import.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if boxes.isEmpty {
                        Text("No boxes configured yet — Configure boxes… picks which categories and fields stage here.")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.Text.disabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(boxes) { box in
                        StagingBoxView(
                            box: box,
                            vocabulary: model.vocabulary,
                            fields: (try? model.library.fields(scope: .mediaItem)) ?? [],
                            folderWords: folderWords,
                            draft: draftBinding,
                            onSticky: { sticky in
                                setSticky(box, sticky)
                            })
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Flags").modifier(Theme.sectionLabel())
                        Toggle(isOn: draftBinding.clearsNeedsReview) {
                            Text("Already reviewed").font(Theme.ui(12))
                        }
                        .toggleStyle(.checkbox)
                        Toggle(isOn: draftBinding.marksFavorite) {
                            Text("Favourite").font(Theme.ui(12))
                        }
                        .toggleStyle(.checkbox)
                    }
                    .foregroundStyle(Theme.Text.secondary)
                }
                .padding(12)
            }

            Rectangle().fill(Theme.Border.standard).frame(height: 1)
            VStack(alignment: .leading, spacing: 5) {
                Text("Will apply").modifier(Theme.sectionLabel())
                Text(willApplySummary)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(
                        willApplySummary.hasPrefix("Nothing")
                            ? Theme.Text.disabled : Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(width: 340)
        .background(Theme.Surface.raised)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let outcome {
                Text("\(outcome.newCount) new")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Status.green)
                Text("\(outcome.knownCount) already in library")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Text.disabled)
                let skipped = outcome.skippedByExtension.values.reduce(0, +)
                if skipped > 0 {
                    Text("\(skipped) extension off")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.Status.orange)
                }
            }
            Spacer()
            Text("\(selectedPaths.count) selected")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.quaternary)
            Button(selectedPaths.isEmpty
                ? "Nothing selected" : "Import \(selectedPaths.count) Files") {
                beginImport()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selectedPaths.isEmpty || step == .importing)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    /// Running is not modal, but it starts that way: a long import must
    /// not hold a window hostage, and a short one should not make you go
    /// looking for it.
    private var runningOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 12) {
                Text("Importing")
                    .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                if let progress {
                    ProgressView(
                        value: Double(progress.current),
                        total: Double(max(progress.total, 1)))
                    Text("\(progress.current) of \(progress.total) probed and inserted")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.Text.quaternary)
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack(spacing: 9) {
                    Spacer()
                    Button("Cancel") { cancelImport() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    Button("Run in background") {
                        step = .review
                        model.refreshAll()
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
            .padding(18)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.window)
                    .fill(Theme.Surface.dialog)
                    .stroke(Theme.Border.raised, lineWidth: 1))
        }
    }

    // MARK: - Derived

    private var folders: [(path: String, new: Int, known: Int)] {
        outcome?.folders() ?? []
    }

    private func paths(in folder: String) -> Set<String> {
        Set((outcome?.candidates ?? [])
            .filter { $0.folderPath == folder }
            .map(\.relativePath))
    }

    private func newPaths(in folder: String) -> Set<String> {
        Set((outcome?.candidates ?? [])
            .filter { $0.folderPath == folder && !$0.isKnown }
            .map(\.relativePath))
    }

    private var visibleCandidates: [ScanCandidate] {
        let query = nameFilter.trimmingCharacters(in: .whitespaces)
        return (outcome?.candidates ?? []).filter { candidate in
            guard checkedFolders.isEmpty || checkedFolders.contains(candidate.folderPath)
            else { return false }
            switch statusFilter {
            case .newOnly: if candidate.isKnown { return false }
            case .alreadyImported: if !candidate.isKnown { return false }
            case .all: break
            }
            guard query.isEmpty else {
                return candidate.fileName.localizedCaseInsensitiveContains(query)
            }
            return true
        }
    }

    /// Words from the focused folder's name, offered as suggestions —
    /// never applied. A filename parser that silently invents tags is
    /// unpickable-apart later.
    private var folderWords: [String] {
        guard let focusedFolder, !focusedFolder.isEmpty else { return [] }
        return focusedFolder
            .split(whereSeparator: { "/-_. ".contains($0) })
            .map(String.init)
            .filter { $0.count > 2 }
    }

    private var draftBinding: Binding<StagingDraft> {
        Binding(
            get: {
                perFolderScope
                    ? folderStaging[focusedFolder ?? "", default: StagingDraft()]
                    : wholeStaging
            },
            set: { draft in
                if perFolderScope {
                    folderStaging[focusedFolder ?? ""] = draft
                } else {
                    wholeStaging = draft
                }
            })
    }

    private var willApplySummary: String {
        let draft = draftBinding.wrappedValue
        guard !draft.isEmpty else { return "Nothing staged yet — files import untagged." }
        var parts: [String] = []
        let names = draft.tagIDs.compactMap { id in
            model.vocabulary.flatMap(\.tags).first { $0.id == id }?.name
        } + draft.pendingNames.map(\.name)
        if !names.isEmpty { parts.append(names.joined(separator: " · ")) }
        if !draft.fieldValues.isEmpty { parts.append("\(draft.fieldValues.count) field values") }
        if draft.clearsNeedsReview { parts.append("already reviewed") }
        if draft.marksFavorite { parts.append("favourite") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Source"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Registering a source SCANS it. Pointing at an unreviewed drive
        // should cost a file list, not four thousand rows you then have
        // to un-import — and there is no un-import.
        if let source = model.addSource(at: url) {
            beginScan(source)
        }
    }

    private func beginScan(_ source: Source) {
        selectedSource = source
        scanError = nil
        step = .scan
        scanTask?.cancel()
        let library = model.library
        scanTask = Task {
            do {
                let result = try await MediaScanner.scan(source: source, library: library)
                guard !Task.isCancelled else { return }
                outcome = result
                boxes = (try? library.importBoxes()) ?? []
                // Sticky boxes arrive already filled.
                wholeStaging = StagingDraft(
                    tagIDs: boxes.filter(\.sticky).flatMap(\.stickyTagIDs),
                    fieldValues: Dictionary(
                        uniqueKeysWithValues: boxes.compactMap { box in
                            guard box.sticky, let fieldID = box.fieldID,
                                  let value = box.stickyValue else { return nil }
                            return (fieldID, value)
                        }))
                folderStaging = [:]
                checkedFolders = Set(result.folders().map(\.path))
                focusedFolder = result.folders().first?.path
                selectedPaths = Set(result.candidates.filter { !$0.isKnown }.map(\.relativePath))
                step = .review
            } catch {
                scanError = "\(error)"
                step = .source
            }
        }
    }

    /// Enabling a skipped extension writes THIS LIBRARY's override, not
    /// the app-wide list — the question was about this drive.
    private func enableExtension(_ ext: String) {
        let settings = AppSettingsStore.shared.current
        do {
            let info = try model.library.info()
            let video = info?.effectiveVideoExtensions(appWide: settings.videoExtensions)
                ?? Set(settings.videoExtensions)
            let audio = info?.effectiveAudioExtensions(appWide: settings.audioExtensions)
                ?? Set(settings.audioExtensions)
            // Video by default: an unknown container is far more often
            // video, and the lists are visible in Settings either way.
            try model.library.setExtensionOverrides(
                video: (video.union([ext])).sorted(), audio: audio.sorted())
            if let selectedSource { beginScan(selectedSource) }
        } catch {
            scanError = "\(error)"
        }
    }

    private func beginImport() {
        guard let source = selectedSource else { return }
        step = .importing
        progress = nil
        let runner = try? app.runner(for: model.libraryID)
        guard let runner else { return }
        let library = model.library
        // Per-folder staging is several payloads, one per folder — the
        // job does not learn a second shape.
        let groups: [(paths: [String], staging: ImportStaging)] = perFolderScope
            ? Dictionary(grouping: selectedPaths) { path in MediaPath.folder(of: path) }
                .map { folder, paths in
                    (paths.sorted(), (folderStaging[folder] ?? StagingDraft()).staging(in: library))
                }
            : [(selectedPaths.sorted(), wholeStaging.staging(in: library))]

        Task {
            var inserted = 0
            var skipped = 0
            for group in groups where !group.paths.isEmpty {
                do {
                    await runner.register(ImportJob.self)
                    let record = try await ImportJob.enqueue(
                        on: runner, sourceID: source.id,
                        relativePaths: group.paths,
                        staging: group.staging.isEmpty ? nil : group.staging)
                    running = record
                    let drain = Task { try await runner.runPending() }
                    var settled = false
                    while !settled {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard let row = try await library.writer.read({
                            try JobRecord.fetchOne($0, key: record.id)
                        }) else { break }
                        progress = (row.progressCurrent, row.progressTotal ?? group.paths.count)
                        switch row.state {
                        case .queued, .running: break
                        case .succeeded, .failed, .cancelled:
                            settled = true
                            if let summary = row.summary {
                                let numbers = summary.split(separator: " ")
                                    .compactMap { Int($0) }
                                inserted += numbers.first ?? 0
                                skipped += numbers.count > 1 ? numbers[1] : 0
                            }
                        }
                    }
                    _ = try? await drain.value
                } catch {
                    scanError = "\(error)"
                }
            }
            // Sticky boxes keep their values for the next import.
            persistSticky()
            let extensionSkips = outcome?.skippedByExtension.values.reduce(0, +) ?? 0
            finished = """
                \(inserted) media items inserted
                \(skipped) skipped — already in library
                \(extensionSkips) skipped — extension not enabled
                """
            step = .review
            model.refreshAll()
            // Import finishing is a worker signal: new rows want hashes
            // and thumbnails.
            app.signalMaintenance(for: model.libraryID)
        }
    }

    private func cancelImport() {
        guard let running, let runner = try? app.runner(for: model.libraryID) else { return }
        Task {
            // The job's own cooperative cancellation — it stops between
            // files, so nothing is half-inserted.
            await runner.requestCancel(running.id)
            step = .review
        }
    }

    private func setSticky(_ box: ImportBox, _ sticky: Bool) {
        guard let index = boxes.firstIndex(where: { $0.id == box.id }) else { return }
        boxes[index].sticky = sticky
        try? model.library.setImportBoxes(boxes)
    }

    private func persistSticky() {
        let draft = wholeStaging
        for index in boxes.indices where boxes[index].sticky {
            if let categoryID = boxes[index].categoryID {
                let inCategory = model.vocabulary
                    .first { $0.category.id == categoryID }?.tags.map(\.id) ?? []
                boxes[index].stickyTagIDs = draft.tagIDs.filter { inCategory.contains($0) }
            }
            if let fieldID = boxes[index].fieldID {
                boxes[index].stickyValue = draft.fieldValues[fieldID]
            }
        }
        try? model.library.setImportBoxes(boxes)
    }

    /// Counts, reachability, history and the effective extension lists —
    /// gathered off the main actor, published behind a generation guard.
    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let library = model.library
        let sources = model.sources
        let appSettings = AppSettingsStore.shared.current

        struct Loaded: Sendable {
            var counts: [UUID: Int] = [:]
            var online: [UUID: Bool] = [:]
            var history: [JobRecord] = []
            var video: [String] = []
            var audio: [String] = []
            var hasOverride = false
        }
        let loaded = await Task.detached { () -> Loaded in
            var result = Loaded()
            do {
                // Sync read on purpose — the async overload's closure
                // inference is ambiguous to the CI toolchain (Xcode 16),
                // and this whole task is already off the main actor.
                try library.writer.read { db in
                    let rows = try Row.fetchAll(
                        db, sql: "SELECT sourceID, COUNT(*) AS c FROM mediaItem GROUP BY sourceID")
                    for row in rows {
                        if let id = row["sourceID"] as UUID? {
                            result.counts[id] = row["c"]
                        }
                    }
                    result.history = try JobRecord
                        .filter(sql: "kind = ?", arguments: [ImportJob.kind])
                        .order(sql: "createdAt DESC")
                        .limit(12)
                        .fetchAll(db)
                    let info = try LibraryInfo.fetchOne(db)
                    result.hasOverride = info?.videoExtensionsOverride != nil
                        || info?.audioExtensionsOverride != nil
                    result.video = (info?.effectiveVideoExtensions(appWide: appSettings.videoExtensions)
                        ?? Set(appSettings.videoExtensions.map { $0.lowercased() })).sorted()
                    result.audio = (info?.effectiveAudioExtensions(appWide: appSettings.audioExtensions)
                        ?? Set(appSettings.audioExtensions.map { $0.lowercased() })).sorted()
                }
            } catch {
                // Leave the partial result — the rows render what loaded.
            }
            let fileAccess = LiveFileAccess()
            for source in sources {
                result.online[source.id] = source.isOnline(using: fileAccess)
            }
            return result
        }.value

        guard generation == loadGeneration else { return }
        itemCounts = loaded.counts
        online = loaded.online
        history = loaded.history
        videoExtensions = loaded.video
        audioExtensions = loaded.audio
        hasOverride = loaded.hasOverride
        if boxes.isEmpty { boxes = (try? library.importBoxes()) ?? [] }
    }
}

/// What the rail is staging, before it becomes a payload.
///
/// `pendingNames` are staged words that are not tags yet — a suggestion
/// from a folder name, or something typed. They become tags through
/// `ensureTag` when the import runs, so the category's formatting rule
/// and its aliases apply exactly as they would anywhere else, and
/// nothing is written by merely suggesting.
struct StagingDraft: Equatable {
    var tagIDs: [UUID] = []
    var pendingNames: [PendingTagName] = []
    var fieldValues: [UUID: String] = [:]
    var clearsNeedsReview = false
    var marksFavorite = false

    var isEmpty: Bool {
        tagIDs.isEmpty && pendingNames.isEmpty && fieldValues.isEmpty
            && !clearsNeedsReview && !marksFavorite
    }

    /// Resolve the pending names against the library, then hand the job
    /// a payload of ids.
    func staging(in library: LibraryDatabase) -> ImportStaging {
        var ids = tagIDs
        for pending in pendingNames {
            if let tag = try? library.ensureTag(
                named: pending.name, inCategory: pending.categoryID) {
                ids.append(tag.id)
            }
        }
        return ImportStaging(
            tagIDs: ids, fieldValues: fieldValues,
            clearsNeedsReview: clearsNeedsReview, marksFavorite: marksFavorite)
    }
}

private struct FinishedSummary: Identifiable {
    var text: String
    var id: String { text }
}

private struct StepStrip: View {
    let step: ImportView.Step
    let scanPath: String?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ImportView.Step.allCases, id: \.self) { entry in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: entry))
                        .frame(width: 7, height: 7)
                    Text(entry.title)
                        .font(Theme.ui(12, entry == step ? .semibold : .regular))
                        .foregroundStyle(color(for: entry))
                }
                if entry != ImportView.Step.allCases.last {
                    Text("›")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.disabled)
                }
            }
            Spacer()
            if let scanPath {
                PathText(path: scanPath, size: 10.5)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private func color(for entry: ImportView.Step) -> Color {
        if entry.rawValue < step.rawValue { return Theme.Status.green }
        if entry == step { return Theme.Accent.amber }
        return Theme.Text.disabled
    }
}

/// One candidate row. Duration and resolution fill in when the row is on
/// screen and its probe resolves — `—` until then, because probing four
/// thousand files up front is the import, not a preview of it.
private struct CandidateRow: View {
    let candidate: ScanCandidate
    let probe: ProbeResult?
    let isSelected: Bool
    let sourceRoot: String
    let onToggle: () -> Void
    let onProbed: (ProbeResult) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggle) {
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(isSelected ? Theme.Accent.amber : .clear)
                    .stroke(
                        candidate.isKnown ? Theme.Border.standard
                            : (isSelected ? Theme.Accent.amber : Theme.Border.subtleButtonHover),
                        lineWidth: 1)
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .disabled(candidate.isKnown)
            .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.fileName)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(
                        candidate.isKnown ? Theme.Text.quaternary : Theme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !candidate.folderPath.isEmpty {
                    Text(candidate.folderPath)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.Text.disabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(probe?.durationSeconds.map(TransportBarTime.format) ?? "—")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.Text.quaternary)
                .frame(width: 92, alignment: .trailing)
            Text(ByteCountFormatter.string(fromByteCount: candidate.fileSize, countStyle: .file))
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.Text.quaternary)
                .frame(width: 76, alignment: .trailing)
            statusPill
                .frame(width: 118, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .task(id: candidate.relativePath) {
            guard probe == nil, !sourceRoot.isEmpty else { return }
            let url = URL(fileURLWithPath: sourceRoot, isDirectory: true)
                .appendingPathComponent(candidate.relativePath)
            let result = await MediaProbe.probe(url: url)
            onProbed(result)
        }
    }

    @ViewBuilder private var statusPill: some View {
        if candidate.isKnown {
            ThemeBadge(
                text: "in library", fill: Theme.Surface.iconTile,
                foreground: Theme.Text.quaternary)
        } else {
            ThemeBadge(
                text: "new", fill: Theme.Status.goodBadgeFill,
                foreground: Theme.Status.greenBright)
        }
    }
}

private struct ImportSourceRow: View {
    let source: Source
    let itemCount: Int?
    let isOnline: Bool?
    let onScan: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(isOnline == false ? Theme.Status.orange : Theme.Status.green)
                .frame(width: 8, height: 8)
                .help(isOnline == false ? "Offline — the folder is unreachable" : "Online")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(Theme.ui(12.5))
                        .foregroundStyle(Theme.Text.primary)
                    if !source.enabled {
                        ThemeBadge(
                            text: "disabled", fill: Theme.Surface.iconTile,
                            foreground: Theme.Text.disabled)
                    }
                }
                PathText(path: source.rootPath, size: 10.5)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(itemCount ?? 0) items")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Text.quaternary)
                if let lastSeen = source.lastSeenAt {
                    Text("scanned \(lastSeen.formatted(.relative(presentation: .named)))")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.disabled)
                }
            }
            Button("Scan", action: onScan)
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(!source.enabled || isOnline == false)
                .help(source.enabled
                    ? "Scan this source for new files"
                    : "Enable the source to scan it")
        }
        .padding(.vertical, 4)
    }
}

private struct ImportHistoryRow: View {
    let record: JobRecord

    private var stateLabel: (text: String, color: Color) {
        switch record.state {
        case .queued: ("queued", Theme.Text.disabled)
        case .running: ("running", Theme.Status.blue)
        case .succeeded: ("done", Theme.Status.green)
        case .failed: ("failed", Theme.Status.orange)
        case .cancelled: ("cancelled", Theme.Text.disabled)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(stateLabel.text)
                .font(Theme.ui(10.5))
                .foregroundStyle(stateLabel.color)
                .frame(width: 64, alignment: .leading)
            // Verbatim from the job record — never re-derived here.
            Text(record.summary ?? record.error ?? "—")
                .font(Theme.ui(12))
                .foregroundStyle(
                    record.error == nil ? Theme.Text.secondary : Theme.Text.quaternary)
                .lineLimit(2)
            Spacer()
            Text((record.finishedAt ?? record.createdAt)
                .formatted(date: .abbreviated, time: .shortened))
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.Text.disabled)
        }
    }
}

private struct FinishedSheet: View {
    let summary: String
    let onMore: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import finished")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.primary)
            Text(summary)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Thumbnails and content hashes are queued as background jobs and will fill in on their own.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.disabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                Spacer()
                Button("Import more", action: onMore)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Open in Library", action: onOpen)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(Theme.Surface.dialog)
    }
}
