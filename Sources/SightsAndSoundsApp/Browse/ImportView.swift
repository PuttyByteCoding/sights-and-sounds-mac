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
    @Environment(\.dismiss) private var dismiss

    /// Opened on a source: scan it at once. "Import New Files" on a source
    /// and "Import Now" on an orphan both land here — the one way in,
    /// with the list to review and the tags to stage — in place of an
    /// import that took everything unseen.
    var initialSourceID: UUID? = nil
    @State private var openedOnSource = false

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
    /// What went wrong, on whichever step the window is on. It used to be
    /// drawn only on the Scan step, and every place that set it had just
    /// left that step: a failed scan bounced to Source, a failed import
    /// sat on Review, both without a word.
    @State private var notice: String?
    @State private var scanTask: Task<Void, Never>?
    // Review state. The rail is a tree of the source's folders; clicking
    // one shows and selects the new files under it, ticking adds another.
    // Nothing is chosen to begin with: the flow is pick a folder, stage
    // its tags, import it, then the next — so the window must not decide
    // the first folder for you.
    @State private var selection = ImportFolderSelection()
    @State private var collapsedFolders: Set<String> = []
    @State private var statusFilter: StatusFilter = .newOnly
    @State private var nameFilter = ""
    /// Per source: a path under one source says nothing about the same
    /// path under another, and a rescan of the same source keeps them.
    @State private var probes: [String: ProbeResult] = [:]
    @State private var probedSource: UUID?

    // Staging: one set of boxes, for the import in hand. Sticky boxes
    // keep their values for the next one; the rest clear once it lands.
    @State private var boxes: [ImportBox] = []
    @State private var staging = StagingDraft()
    @State private var showConfigure = false
    /// Saves of the boxes, one at a time in the order made: a save is a
    /// request now, and an older one must not land on top of a newer.
    @State private var boxWrites = WriteQueue()

    // Running
    @State private var run: ImportRun?
    private var progress: (current: Int, total: Int)? { run?.progress }
    @State private var finished: FinishedSummary?
    /// The item-scope fields, read once per reload. They were read from
    /// the database inside `body`, once per staging box per render, and
    /// this view re-renders on every keystroke in any of its fields.
    @State private var itemFields: [FieldDefinition] = []

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
            if let notice {
                noticeBanner(notice)
            }
            switch step {
            case .source: sourceStep
            case .scan: scanStep
            case .review, .importing: reviewStep
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(Theme.Surface.content)
        .task {
            await reload()
            scanInitialSource()
        }
        .onChange(of: model.sources) {
            Task {
                await reload()
                scanInitialSource()
            }
        }
        .sheet(isPresented: $showConfigure) {
            ConfigureBoxesSheet(
                boxes: $boxes,
                categories: model.vocabulary.map(\.category),
                fields: itemFields,
                onSave: { saved in saveBoxes(saved) })
        }
        .sheet(item: $finished) { summary in
            FinishedSheet(
                title: summary.title,
                summary: summary.text,
                onMore: {
                    finished = nil
                    step = .source
                },
                onOpen: {
                    // The library window is behind this one, and its grid
                    // already has the new items: close Import to show it.
                    // It used to close only this sheet.
                    finished = nil
                    dismiss()
                })
        }
        .onDisappear { scanTask?.cancel() }
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
                        // A source is a folder on the Mac that holds the
                        // library, and is added there.
                        Button("Add Folder…") { addFolder() }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                            .help("Register a folder as a source and scan it — nothing is imported until you review the list")
                            .unavailableRemotely(model.isRemote)
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
            Button("Cancel") {
                scanTask?.cancel()
                step = .source
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Status.orange)
            Text(text)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                notice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.ui(9))
                    .foregroundStyle(Theme.Text.disabled)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.Status.warnBadgeFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
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
            Text(statusFilter == .newOnly ? "Folders with new files" : "Folders").modifier(Theme.sectionLabel())
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            ScrollView {
                VStack(spacing: 1) {
                    if folderTree.isEmpty {
                        Text(statusFilter == .newOnly
                            ? "Nothing new under this source."
                            : "No media files under this source.")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.Text.disabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    }
                    ForEach(folderTree) { node in
                        FolderTreeRows(node: node, depth: 0, collapsed: collapsedFolders) {
                            AnyView(folderRow($0, depth: $1))
                        }
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

    private func folderRow(_ node: ScanOutcome.FolderNode, depth: Int) -> some View {
        let checked = selection.checked.contains(node.path)
        let collapsed = collapsedFolders.contains(node.path)
        var counts = "\(node.new) new"
        if statusFilter != .newOnly { counts += " · \(node.known) known" }
        if node.removed > 0 { counts += " · \(node.removed) removed" }
        return HStack(spacing: 6) {
            // Ticking a folder selects the new files under it, subfolders
            // included; unticking it drops them.
            Button {
                toggleFolder(node.path)
            } label: {
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(checked ? Theme.Accent.amber : .clear)
                    .stroke(
                        checked ? Theme.Accent.amber : Theme.Border.subtleButtonHover, lineWidth: 1)
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .disabled(node.new == 0)
            .help(node.new == 0 ? "Nothing new here" : "Select the new files in this folder and its subfolders")
            if node.children.isEmpty {
                Color.clear.frame(width: 10, height: 10)
            } else {
                Button {
                    if collapsed { collapsedFolders.remove(node.path) } else { collapsedFolders.insert(node.path) }
                } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(Theme.ui(9, .semibold))
                        .foregroundStyle(Theme.Text.disabled)
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(Theme.ui(12))
                    .foregroundStyle(node.new > 0 ? Theme.Text.primary : Theme.Text.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(counts)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.leading, 12 + CGFloat(depth) * 14)
        .padding(.trailing, 12)
        .background(selection.focused == node.path ? Theme.Surface.selectedRow : .clear)
        .contentShape(Rectangle())
        // Clicking the name makes this folder the scope: its files in the
        // table, its new ones selected, its words as tag suggestions. It
        // used to tick the folder only while nothing else was ticked, so
        // the second folder clicked showed the first folder's files.
        .onTapAsButton {
            if let outcome { selection.click(node.path, in: outcome) }
        }
    }

    private func toggleFolder(_ path: String) {
        guard let outcome else { return }
        selection.toggle(path, in: outcome)
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
                Text(selection.checked.isEmpty
                    ? "Click a folder on the left to see its files."
                    : "No files match this scope and filter.")
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
                                isSelected: selection.paths.contains(candidate.relativePath),
                                measure: measurer(of: candidate.relativePath),
                                onToggle: {
                                    guard !candidate.isKnown else { return }
                                    selection.toggleFile(candidate.relativePath)
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
            Text("Applies to every selected file in this import. Sticky boxes keep their values for the next one; the rest clear once it lands.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

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
                            fields: itemFields,
                            folderWords: folderWords,
                            draft: $staging,
                            onSticky: { sticky in
                                setSticky(box, sticky)
                            })
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Flags").modifier(Theme.sectionLabel())
                        Toggle(isOn: $staging.clearsNeedsReview) {
                            Text("Already reviewed").font(Theme.ui(12))
                        }
                        .toggleStyle(.checkbox)
                        Toggle(isOn: $staging.marksFavorite) {
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
                if outcome.removedCount > 0 {
                    Text("\(outcome.removedCount) removed")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.Text.disabled)
                }
                let skipped = outcome.skippedByExtension.values.reduce(0, +)
                if skipped > 0 {
                    Text("\(skipped) extension off")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.Status.orange)
                }
            }
            Spacer()
            Text("\(selection.paths.count) selected")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.quaternary)
            Button(importButtonTitle) {
                beginImport()
            }
            .buttonStyle(PrimaryButtonStyle())
            // Off while ANY run is live, not just while the overlay shows:
            // "Run in background" left it armed, and a second press
            // imported the same files again.
            .disabled(selection.paths.isEmpty || run?.isRunning == true)
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

    private var folderTree: [ScanOutcome.FolderNode] {
        outcome?.folderTree(newOnly: statusFilter == .newOnly) ?? []
    }

    /// The files under the folders in scope. None chosen, none shown:
    /// the rail is the scope, and an empty scope used to show everything.
    private var visibleCandidates: [ScanCandidate] {
        let query = nameFilter.trimmingCharacters(in: .whitespaces)
        return (outcome?.candidates ?? []).filter { candidate in
            guard selection.checked.contains(where: { ScanOutcome.isUnder(candidate.folderPath, $0) })
            else { return false }
            switch statusFilter {
            case .newOnly: if !candidate.isNew { return false }
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
        guard let focusedFolder = selection.focused, !focusedFolder.isEmpty else { return [] }
        return focusedFolder
            .split(whereSeparator: { "/-_. ".contains($0) })
            .map(String.init)
            .filter { $0.count > 2 }
    }

    /// What the sticky boxes kept from the last import — only values that
    /// still exist: a sticky tag since deleted left a dead id in the draft
    /// that showed as an empty "Will apply" with no pill to remove.
    private func stickyDraft() -> StagingDraft {
        let present = Set(model.vocabulary.flatMap(\.tags).map(\.id))
        return StagingDraft(
            tagIDs: boxes.filter(\.sticky).flatMap(\.stickyTagIDs).filter { present.contains($0) },
            fieldValues: Dictionary(
                uniqueKeysWithValues: boxes.compactMap { box in
                    guard box.sticky, let fieldID = box.fieldID,
                          let value = box.stickyValue else { return nil }
                    return (fieldID, value)
                }))
    }

    private var willApplySummary: String {
        let draft = staging
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
        Task {
            if let source = await model.addSource(at: url) {
                beginScan(source)
            }
        }
    }

    /// Once, as soon as the source list holds the one asked for.
    private func scanInitialSource() {
        guard !openedOnSource, let id = initialSourceID,
              let source = model.sources.first(where: { $0.id == id })
        else { return }
        openedOnSource = true
        beginScan(source)
    }

    private func beginScan(_ source: Source) {
        selectedSource = source
        notice = nil
        step = .scan
        scanTask?.cancel()
        let service = model.service
        scanTask = Task {
            do {
                // The folder is listed where it is: by the library's
                // service, on the Mac that holds it.
                let result = try await service.scanSource(sourceID: source.id)
                guard !Task.isCancelled else { return }
                let saved = (try? await service.importBoxes()) ?? []
                guard !Task.isCancelled else { return }
                outcome = result
                boxes = saved
                // Sticky boxes arrive already filled.
                staging = stickyDraft()
                if probedSource != source.id {
                    probes = [:]
                    probedSource = source.id
                }
                // Nothing chosen, nothing selected: pick a folder first.
                selection.reset(focusing: result.folderTree(newOnly: true).first?.path)
                collapsedFolders = []
                step = .review
            } catch {
                notice = "Scan of \(source.name) failed: \(error)"
                step = .source
            }
        }
    }

    /// Enabling a skipped extension writes THIS LIBRARY's override, not
    /// the app-wide list — the question was about this drive.
    private func enableExtension(_ ext: String) {
        let service = model.service
        Task {
            do {
                try await service.enableExtension(ext)
                if let selectedSource { beginScan(selectedSource) }
            } catch {
                notice = "Could not enable .\(ext): \(error)"
            }
        }
    }

    /// What measures one of the selected source's files, wherever the
    /// source is. Nil when it could not be asked, so the row asks again
    /// rather than keeping an empty answer.
    private func measurer(of relativePath: String) -> @Sendable () async -> ProbeResult? {
        guard let sourceID = selectedSource?.id else { return { nil } }
        let service = model.service
        return { try? await service.probeFile(sourceID: sourceID, relativePath: relativePath) }
    }

    private func saveBoxes(_ boxes: [ImportBox]) {
        let service = model.service
        boxWrites.send { try await service.setImportBoxes(boxes) }
    }

    private var importButtonTitle: String {
        if run?.isRunning == true { return "Importing…" }
        return selection.paths.isEmpty ? "Nothing selected" : "Import \(selection.paths.count) Files"
    }

    private func beginImport() {
        guard let source = selectedSource, run?.isRunning != true else { return }
        let service = model.service
        let imported = selection.paths
        let sent = staging

        // A library whose jobs cannot be started says so in the run's
        // own result, which brings the window back to Review.
        let run = ImportRun(service: service)
        self.run = run
        step = .importing
        run.start(sourceID: source.id, preparing: {
            let resolved = await sent.staging(through: service)
            return [ImportRun.Group(paths: imported.sorted(), staging: resolved.isEmpty ? nil : resolved)]
        }) { result in
            let tally = result.tally
            // Sticky boxes keep their values for the next import.
            persistSticky()
            let extensionSkips = outcome?.skippedByExtension.values.reduce(0, +) ?? 0
            var lines = [
                "\(tally.inserted) media items inserted",
                "\(tally.skipped) skipped — already in library",
                "\(extensionSkips) skipped — extension not enabled",
            ]
            if result.cancelled { lines.append("stopped before the rest") }
            lines += result.failures.map { "failed: \($0)" }
            finished = FinishedSummary(
                title: result.cancelled ? "Import cancelled"
                    : result.failures.isEmpty ? "Import finished" : "Import finished with errors",
                text: lines.joined(separator: "\n"))
            step = .review
            // Import finishing is a worker signal: new rows want hashes
            // and thumbnails.
            app.signalMaintenance(for: model.libraryID)
            // The scan on screen is updated in place — a rescan threw away
            // every tick and staged value typed since, and a folder ticked
            // for the next import while this one ran in the background is
            // kept. What went in is known now; a cancelled or failed run
            // rescans instead, since what landed is not known here.
            guard !result.cancelled, result.failures.isEmpty else {
                if let selectedSource { beginScan(selectedSource) }
                return
            }
            let updated = outcome?.markingKnown(imported)
            outcome = updated
            if let updated { selection.afterImport(imported, updated: updated) }
            // The boxes keep only their sticky values — unless they were
            // changed since Import was pressed, which is the next import's.
            if staging == sent { staging = stickyDraft() }
        }
    }

    /// Stops the whole run — every later folder too — and the job in
    /// flight between files, so nothing is half-inserted.
    private func cancelImport() {
        run?.cancel()
        step = .review
    }

    private func setSticky(_ box: ImportBox, _ sticky: Bool) {
        guard let index = boxes.firstIndex(where: { $0.id == box.id }) else { return }
        boxes[index].sticky = sticky
        saveBoxes(boxes)
    }

    private func persistSticky() {
        let draft = staging
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
        saveBoxes(boxes)
    }

    /// Counts, reachability, history and the effective extension lists —
    /// gathered off the main actor, published behind a generation guard.
    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let service = model.service
        let fields = (try? await service.fields(scope: .mediaItem, categoryID: nil)) ?? []
        // Leave what is shown when the library could not be asked.
        let overview = try? await service.importOverview()
        let saved = boxes.isEmpty ? try? await service.importBoxes() : nil

        guard generation == loadGeneration else { return }
        itemFields = fields
        if let overview {
            itemCounts = overview.itemCounts
            online = overview.online
            history = overview.history
            videoExtensions = overview.videoExtensions
            audioExtensions = overview.audioExtensions
            hasOverride = overview.hasOverride
        }
        if boxes.isEmpty, let saved { boxes = saved }
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
    func staging(through service: any LibraryService) async -> ImportStaging {
        var ids = tagIDs
        for pending in pendingNames {
            if let tag = try? await service.ensureTag(
                named: pending.name, inCategory: pending.categoryID) {
                ids.append(tag.id)
            }
        }
        return ImportStaging(
            tagIDs: ids, fieldValues: fieldValues,
            clearsNeedsReview: clearsNeedsReview, marksFavorite: marksFavorite)
    }
}

/// A folder and, unless collapsed, its subfolders beneath it. A struct,
/// because a function returning `some View` may not call itself.
private struct FolderTreeRows: View {
    let node: ScanOutcome.FolderNode
    let depth: Int
    let collapsed: Set<String>
    let row: (ScanOutcome.FolderNode, Int) -> AnyView

    var body: some View {
        row(node, depth)
        if !collapsed.contains(node.path) {
            ForEach(node.children) { child in
                FolderTreeRows(node: child, depth: depth + 1, collapsed: collapsed, row: row)
            }
        }
    }
}

private struct FinishedSummary: Identifiable, Equatable {
    var title: String
    var text: String
    var id: String { title + text }
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
    /// Measures the file, on the Mac that has it.
    let measure: @Sendable () async -> ProbeResult?
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
        .onTapAsButton(perform: onToggle)
        .task(id: candidate.relativePath) {
            guard probe == nil, let result = await measure() else { return }
            onProbed(result)
        }
    }

    @ViewBuilder private var statusPill: some View {
        if candidate.isKnown {
            ThemeBadge(
                text: "in library", fill: Theme.Surface.iconTile,
                foreground: Theme.Text.quaternary)
        } else if candidate.isRemoved {
            ThemeBadge(
                text: "removed", fill: Theme.Surface.iconTile,
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
    let title: String
    let summary: String
    let onMore: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
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
