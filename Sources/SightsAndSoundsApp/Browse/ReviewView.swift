import SwiftUI
import SightsAndSoundsKit

/// Three queues that are the same shape: a flagged list, evidence, a
/// decision, and a batch confirm.
///
/// **Duplicates** asks which copy survives; answering it stages the
/// loser. **Delete list** asks whether you are done — everything marked
/// `D` during a triage pass is already waiting there, so the two paths
/// converge on one button. **Playback issues** asks what to do about a
/// file that would not play, with the evidence captured at the moment it
/// failed.
///
/// The compare screen never deletes anything, and nothing leaves disk
/// except from the delete list.
struct ReviewView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(AppModel.self) private var app

    enum Mode: String, CaseIterable {
        case duplicates, deleteList, issues

        func title(_ count: Int) -> String {
            switch self {
            case .duplicates: "Duplicates \(count)"
            case .deleteList: "Delete list \(count)"
            case .issues: "Playback issues \(count)"
            }
        }

        /// The safety line, which changes per mode because the promise
        /// does.
        var safety: String {
            switch self {
            case .duplicates: "Resolving a group only moves the losing copy to the delete list."
            case .deleteList: "Files leave disk only when you delete them here."
            case .issues: "Every fix archives the original first."
            }
        }
    }

    @State private var mode: Mode = .duplicates
    @State private var candidates: [DuplicateCandidate] = []
    @State private var itemsByID: [UUID: MediaItem] = [:]
    @State private var selectedCandidateID: UUID?
    @State private var deleteList: [MediaItem] = []
    @State private var deleteTicked: Set<UUID> = []
    @State private var issues: [MediaItem] = []
    @State private var selectedIssueID: UUID?
    @State private var evidence: PlaybackIssueEvidence?
    @State private var recipes: [RepairRecipe] = []
    @State private var pickedRecipeID: UUID?
    @State private var reclaimable: Int64 = 0
    @State private var errorText: String?
    @State private var resolvedThisPass: [Mode: Int] = [:]
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                queueRail
                Rectangle().fill(Theme.Border.standard).frame(width: 1)
                centre
            }
            footer
        }
        .frame(minWidth: 980, minHeight: 600)
        .background(Theme.Surface.content)
        .onAppear { reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ThemeSegmentedControl(
                selection: $mode,
                options: [
                    (Mode.duplicates, Mode.duplicates.title(candidates.count)),
                    (Mode.deleteList, Mode.deleteList.title(deleteList.count)),
                    (Mode.issues, Mode.issues.title(issues.count)),
                ],
                emphasis: .neutral)
            Text(headline)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.quaternary)
            Spacer()
            Text(mode.safety)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.disabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var headline: String {
        switch mode {
        case .duplicates: "\(candidates.count) pairs awaiting a decision"
        case .deleteList:
            "\(deleteList.count) marked · \(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file)) reclaimable"
        case .issues: "\(issues.count) files flagged"
        }
    }

    // MARK: - Queue rail

    private var queueRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    switch mode {
                    case .duplicates:
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    case .deleteList:
                        ForEach(deleteList) { item in
                            queueRow(
                                title: item.fileName,
                                meta: markedBy(item),
                                dot: Theme.Status.red,
                                selected: false,
                                onSelect: {})
                        }
                    case .issues:
                        ForEach(issues) { item in
                            queueRow(
                                title: item.fileName,
                                meta: item.folderPath,
                                dot: Theme.Status.orange,
                                selected: selectedIssueID == item.id,
                                onSelect: { select(issue: item) })
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            // Counted PER QUEUE — the three share one window and must
            // never borrow each other's numbers.
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("This pass").modifier(Theme.sectionLabel())
                ForEach(Mode.allCases, id: \.self) { entry in
                    HStack {
                        Text(entry.title(0).replacingOccurrences(of: " 0", with: ""))
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.Text.disabled)
                        Spacer()
                        Text("\(resolvedThisPass[entry] ?? 0)")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(
                                (resolvedThisPass[entry] ?? 0) == 0
                                    ? Theme.Text.zeroCount : Theme.Status.green)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 262)
        .background(Theme.Surface.sidebar)
    }

    private func candidateRow(_ candidate: DuplicateCandidate) -> some View {
        let a = itemsByID[candidate.itemAID]?.fileName ?? "?"
        let b = itemsByID[candidate.itemBID]?.fileName ?? "?"
        var meta = sourceLabel(candidate)
        if let confidence = candidate.confidence {
            meta += String(format: " · %.0f%%", confidence * 100)
        }
        return queueRow(
            title: a, meta: "\(b)\n\(meta)",
            dot: Theme.Status.mauve,
            selected: selectedCandidateID == candidate.id,
            onSelect: { selectedCandidateID = candidate.id })
    }

    private func queueRow(
        title: String, meta: String, dot: Color, selected: Bool, onSelect: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dot).frame(width: 6, height: 6).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(selected ? Theme.Surface.selectedRow : .clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(Theme.Accent.amber)
                    .frame(width: Theme.Border.selectionInsetWidth)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private func sourceLabel(_ candidate: DuplicateCandidate) -> String {
        switch candidate.source {
        case .manual: "manual"
        case .fingerprint: "fingerprint"
        case .contentHash: "identical file"
        }
    }

    private func markedBy(_ item: MediaItem) -> String {
        let reason = item.relativePath.lowercased().hasPrefix("_todelete/")
            ? "staged" : "triage pass"
        return "\(reason) · \(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))"
    }

    // MARK: - Centre

    @ViewBuilder private var centre: some View {
        switch mode {
        case .duplicates: duplicatesCentre
        case .deleteList: deleteCentre
        case .issues: issuesCentre
        }
    }

    @ViewBuilder private var duplicatesCentre: some View {
        if let candidate = candidates.first(where: { $0.id == selectedCandidateID }),
           let a = itemsByID[candidate.itemAID], let b = itemsByID[candidate.itemBID] {
            CompareView(
                candidate: candidate, itemA: a, itemB: b,
                onResolved: {
                    resolvedThisPass[.duplicates, default: 0] += 1
                    reload()
                })
                .id(candidate.id)
        } else {
            empty(
                title: candidates.isEmpty ? "No pending duplicates" : "Pick a pair",
                detail: candidates.isEmpty
                    ? "The sweeps flag identical files and fingerprint matches here."
                    : "Pick the one to keep. The others move to the delete list — this screen never deletes anything itself.")
        }
    }

    @ViewBuilder private var deleteCentre: some View {
        if deleteList.isEmpty {
            empty(
                title: "Nothing marked for deletion",
                detail: "Press D during a triage pass, or resolve a duplicate group, and the files land here.")
        } else {
            VStack(spacing: 0) {
                Text("Everything marked with D during triage, plus the losing copy of every duplicate you have resolved. Nothing here has been touched yet.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                HStack(spacing: 0) {
                    Color.clear.frame(width: 30)
                    Text("File").modifier(Theme.sectionLabel())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Marked by").modifier(Theme.sectionLabel()).frame(width: 150, alignment: .leading)
                    Text("Size").modifier(Theme.sectionLabel()).frame(width: 84, alignment: .trailing)
                    Color.clear.frame(width: 108)
                }
                .padding(.horizontal, 14)
                .frame(height: 31)
                .background(Theme.Surface.toolbar)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.Border.standard).frame(height: 1)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(deleteList) { item in
                            deleteRow(item)
                        }
                    }
                }
            }
        }
    }

    private func deleteRow(_ item: MediaItem) -> some View {
        HStack(spacing: 0) {
            Button {
                toggleDelete(item)
            } label: {
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(deleteTicked.contains(item.id) ? Theme.Accent.amber : .clear)
                    .stroke(
                        deleteTicked.contains(item.id)
                            ? Theme.Accent.amber : Theme.Border.subtleButtonHover,
                        lineWidth: 1)
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.folderPath)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(markedBy(item).components(separatedBy: " · ").first ?? "")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.quaternary)
                .frame(width: 150, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.Text.quaternary)
                .frame(width: 84, alignment: .trailing)
            Button("Restore") { restore(item) }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .frame(width: 108, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var issuesCentre: some View {
        if let item = issues.first(where: { $0.id == selectedIssueID }) {
            IssueDetail(
                item: item,
                evidence: evidence,
                recipes: recipes,
                pickedRecipeID: $pickedRecipeID)
        } else {
            empty(
                title: issues.isEmpty ? "No playback issues" : "Pick a file",
                detail: issues.isEmpty
                    ? "Press W in the player when a file will not play, and it lands here with what the probe said."
                    : "The queue shows what the probe said when the file failed, and the fixes that address it.")
        }
    }

    private func empty(title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(Theme.ui(15, .semibold))
                .foregroundStyle(Theme.Text.quaternary)
            Text(detail)
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.Text.disabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(consequence)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let errorText {
                Text(errorText)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Status.red)
                    .lineLimit(2)
            }
            switch mode {
            case .duplicates:
                EmptyView()
            case .deleteList:
                Button("Restore selected") { restoreSelected() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(deleteTicked.isEmpty)
                Button("Delete \(deleteTicked.count) files") { confirmDelete = true }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(deleteTicked.isEmpty)
                    .confirmationDialog(
                        "Delete \(deleteTicked.count) files?", isPresented: $confirmDelete
                    ) {
                        Button("Delete", role: .destructive) { purge() }
                    } message: {
                        Text("Files move to the purge list and are removed on the next maintenance pass. The operation log keeps a revert entry until then.")
                    }
            case .issues:
                Button("Run fix") { runFix() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(pickedRecipeID == nil)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var consequence: String {
        switch mode {
        case .duplicates:
            "Keeping one copy sends the rest to the delete list. Nothing is removed from disk here."
        case .deleteList:
            deleteTicked.isEmpty
                ? "Nothing selected. Tick the files you want gone."
                : "Deleting moves files to a purge list; they leave disk on the next maintenance pass."
        case .issues:
            pickedRecipeID == nil
                ? "Pick a fix to run against this file."
                : "Runs on a copy. The original is archived and the result is re-probed before it replaces anything."
        }
    }

    // MARK: - Actions

    /// Unticking must actually unstage: `purgeDeleted` takes the ids it
    /// is given, but the FLAG is still the guard inside it, so a row that
    /// stays flagged and unticked would be a lie in the confirmation
    /// count if the view merely filtered.
    private func toggleDelete(_ item: MediaItem) {
        if deleteTicked.contains(item.id) {
            deleteTicked.remove(item.id)
        } else {
            deleteTicked.insert(item.id)
        }
    }

    private func restore(_ item: MediaItem) {
        do {
            try model.library.unstage(.toDelete, itemID: item.id)
            deleteTicked.remove(item.id)
            reload()
        } catch { errorText = "\(error)" }
    }

    private func restoreSelected() {
        for id in deleteTicked {
            try? model.library.unstage(.toDelete, itemID: id)
        }
        deleteTicked = []
        reload()
    }

    private func purge() {
        do {
            let outcome = try model.library.purgeDeleted(itemIDs: Array(deleteTicked))
            resolvedThisPass[.deleteList, default: 0] += outcome.rowsDeleted
            errorText = outcome.fileFailures.isEmpty
                ? nil : outcome.fileFailures.joined(separator: "; ")
            deleteTicked = []
            reload()
            model.refreshAll()
        } catch { errorText = "\(error)" }
    }

    private func select(issue item: MediaItem) {
        selectedIssueID = item.id
        pickedRecipeID = nil
        evidence = try? model.library.playbackIssueEvidence(of: item.id)
        // Recipes are data: what is offered follows the failure kind,
        // cheapest first, and anything unmatched still offers the
        // last-resort ones.
        recipes = (try? app.appDatabase?.repairRecipes(forFailureKind: evidence?.failureKind)) ?? []
    }

    private func runFix() {
        guard let itemID = selectedIssueID,
              let recipe = recipes.first(where: { $0.id == pickedRecipeID }),
              let runner = try? app.runner(for: model.libraryID)
        else { return }
        Task {
            do {
                await runner.register(RepairJob.self)
                _ = try await RepairJob.enqueue(on: runner, itemID: itemID, recipe: recipe)
                try await runner.runPending()
                resolvedThisPass[.issues, default: 0] += 1
                reload()
                model.refreshAll()
            } catch { errorText = "\(error)" }
        }
    }

    /// The candidate/item fetch runs off the main actor — the window's
    /// open used to block on it.
    private func reload() {
        let library = model.library
        Task {
            do {
                let (fetched, items) = try await Task.detached(priority: .userInitiated) {
                    let fetched = try library.pendingCandidates()
                    let ids = Set(fetched.flatMap { [$0.itemAID, $0.itemBID] })
                    let items = try await library.writer.read { db in
                        Dictionary(
                            uniqueKeysWithValues: try MediaItem.fetchAll(db, keys: Array(ids))
                                .map { ($0.id, $0) })
                    }
                    return (fetched, items)
                }.value
                candidates = fetched
                itemsByID = items
                if selectedCandidateID == nil
                    || !candidates.contains(where: { $0.id == selectedCandidateID }) {
                    selectedCandidateID = candidates.first?.id
                }
                deleteList = try await library.writer.read { db in
                    try MediaItem
                        .filter(sql: "markedForDeletion = 1")
                        .order(sql: "relativePath").fetchAll(db)
                }
                // Everything on the list is ticked to start with: the
                // list exists because you already marked these.
                deleteTicked = deleteTicked.isEmpty
                    ? Set(deleteList.map(\.id))
                    : deleteTicked.intersection(deleteList.map(\.id))
                issues = try await library.writer.read { db in
                    try MediaItem
                        .filter(sql: "playbackIssue = 1")
                        .order(sql: "relativePath").fetchAll(db)
                }
                if selectedIssueID == nil || !issues.contains(where: { $0.id == selectedIssueID }) {
                    if let first = issues.first { select(issue: first) } else { selectedIssueID = nil }
                }
                reclaimable = (try? library.reclaimableBytes()) ?? 0
                try? app.appDatabase?.seedRepairRecipes()
                model.refreshAll()
            } catch {
                errorText = "\(error)"
            }
        }
    }
}

/// The destructive confirm — the only place red fills.
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(Theme.TypeScale.body, .semibold))
            .foregroundStyle(isEnabled ? Theme.Status.destructiveText : Theme.Text.disabled)
            .padding(.vertical, 7)
            .padding(.horizontal, 17)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.button)
                    .fill(isEnabled ? Theme.Status.destructiveFill : Theme.Surface.buttonDisabled))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(Rectangle())
    }
}

/// What the probe said when the file failed, and the fixes that address
/// that failure — cheapest first, with the command visible.
private struct IssueDetail: View {
    @Environment(BrowseModel.self) private var model
    let item: MediaItem
    let evidence: PlaybackIssueEvidence?
    let recipes: [RepairRecipe]
    @Binding var pickedRecipeID: UUID?
    @State private var thumbnail: NSImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.page)
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                    .frame(width: 220, height: 124)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.fileName)
                            .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        PathText(path: item.relativePath, size: 10.5)
                        if let evidence {
                            HStack(spacing: 6) {
                                Text(PlaybackFailureKind(rawValue: evidence.failureKind ?? "")?
                                    .displayName ?? "Unclassified")
                                    .font(Theme.ui(11.5))
                                    .foregroundStyle(Theme.Status.orange)
                                Text("captured \(evidence.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(Theme.Text.disabled)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("What the probe said").modifier(Theme.sectionLabel())
                    Text(evidence?.probeOutput ?? "No probe output was captured for this file.")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.Text.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(Theme.Surface.well)
                                .stroke(Theme.Border.standard, lineWidth: 1))
                    Text("Captured when the file failed, not re-run now — a clean probe today would answer a different question.")
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.disabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Fixes").modifier(Theme.sectionLabel())
                    ForEach(recipes) { recipe in
                        recipeRow(recipe)
                    }
                    if recipes.isEmpty {
                        Text("No repair recipes configured.")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                }
            }
            .padding(16)
        }
        .task(id: item.id) {
            let data = await ThumbnailProvider.shared.thumbnailData(
                itemID: item.id, libraryID: model.libraryID,
                fileURL: model.fileURL(for: item), durationSeconds: item.durationSeconds)
            thumbnail = data.flatMap(NSImage.init(data:))
        }
    }

    private func recipeRow(_ recipe: RepairRecipe) -> some View {
        let picked = pickedRecipeID == recipe.id
        return Button {
            pickedRecipeID = picked ? nil : recipe.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(recipe.name)
                        .font(Theme.ui(12.5, picked ? .semibold : .regular))
                        .foregroundStyle(Theme.Text.primary)
                    // Re-encoding is labelled where it is offered: both
                    // are legitimate, only one should be reached for
                    // first.
                    Text(recipe.risk.displayName)
                        .font(Theme.ui(9.5))
                        .foregroundStyle(
                            recipe.risk == .lossy ? Theme.Status.orange : Theme.Status.green)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .fill(recipe.risk == .lossy
                                    ? Theme.Status.warnBadgeFill : Theme.Status.goodBadgeFill))
                    Spacer(minLength: 0)
                    Text(recipe.estimate)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.disabled)
                }
                if !recipe.notes.isEmpty {
                    Text(recipe.notes)
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.tertiary)
                }
                Text(recipe.command(input: item.fileName, output: "repaired-\(item.fileName)"))
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(picked ? Theme.Surface.selectedRow : Theme.Surface.raised)
                    .stroke(picked ? Theme.Accent.amber : Theme.Border.standard, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The side-by-side compare. The matcher proposes: a quality score with
/// its labelled breakdown, a metric-by-metric comparison with the better
/// value marked, and why the pair matched at all.
///
/// **Keep both** is not the same as **Not duplicates**: a pro-shot and an
/// audience capture of the same set match at 94% and are both worth
/// having, and the matcher does not know that.
private struct CompareView: View {
    @Environment(BrowseModel.self) private var model
    let candidate: DuplicateCandidate
    let itemA: MediaItem
    let itemB: MediaItem
    let onResolved: () -> Void

    @State private var keeperID: UUID?
    @State private var mergeSelection: Set<UUID> = []
    @State private var mergeableTags: [Tag] = []
    @State private var outcomeText: String?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pick the one to keep. The others move to the delete list — this screen never deletes anything itself.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.tertiary)
                HStack(alignment: .top, spacing: 14) {
                    ComparePane(
                        item: itemA, other: itemB,
                        isKeeper: keeperID == itemA.id,
                        isBestQuality: bestQualityID == itemA.id) { choose(itemA.id) }
                    ComparePane(
                        item: itemB, other: itemA,
                        isKeeper: keeperID == itemB.id,
                        isBestQuality: bestQualityID == itemB.id) { choose(itemB.id) }
                }
                whyMatched
                if let keeperID { mergePanel(keeperID: keeperID) } else { unresolvedActions }
                if let errorText {
                    Text(errorText).font(Theme.ui(11.5)).foregroundStyle(Theme.Status.red)
                }
                if let outcomeText {
                    Text(outcomeText).font(Theme.ui(11.5)).foregroundStyle(Theme.Text.tertiary)
                }
            }
            .padding(16)
        }
    }

    private var bestQualityID: UUID? {
        let a = QualityScore.compute(for: itemA).total
        let b = QualityScore.compute(for: itemB).total
        if abs(a - b) < 0.5 { return nil }
        return a > b ? itemA.id : itemB.id
    }

    /// Why these matched — including the reliability floor, where it is
    /// the reason a pair is absent rather than present.
    private var whyMatched: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Why these matched").modifier(Theme.sectionLabel())
            ForEach(reasons, id: \.self) { reason in
                Text("· \(reason)")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.tertiary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Surface.raised)
                .stroke(Theme.Border.standard, lineWidth: 1))
    }

    private var reasons: [String] {
        var lines: [String] = []
        switch candidate.source {
        case .contentHash:
            lines.append("Identical file contents — the same hash, byte for byte.")
        case .fingerprint:
            if let confidence = candidate.confidence {
                lines.append(String(
                    format: "Audio fingerprint match at %.0f%%.", confidence * 100))
            }
            if let kind = candidate.matchKind {
                lines.append(kind == .sameRecording
                    ? "Scored as the same recording end to end."
                    : "Scored as containment — one is a part of the other.")
            }
            lines.append("Fingerprint matching needs 25 seconds of audio; shorter files never appear here at all.")
        case .manual:
            lines.append("Flagged by hand.")
        }
        if let a = itemA.durationSeconds, let b = itemB.durationSeconds {
            lines.append(String(format: "Duration differs by %.1f s.", abs(a - b)))
        }
        return lines
    }

    private var unresolvedActions: some View {
        HStack(spacing: 9) {
            Text("Choose which file to keep, or say the matcher got it wrong.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.disabled)
            Spacer()
            Button("Keep both") { keepBoth() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Both copies are wanted — the pair leaves the queue and neither file is staged")
            Button("Not Duplicates") { reject() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("The matcher got it wrong — the pair is never re-flagged")
        }
    }

    @ViewBuilder
    private func mergePanel(keeperID: UUID) -> some View {
        let loser = keeperID == itemA.id ? itemB : itemA
        VStack(alignment: .leading, spacing: 8) {
            if !mergeableTags.isEmpty {
                Text("Carry these tags from the file being removed:")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.secondary)
                FlowRow(spacing: 5) {
                    ForEach(mergeableTags) { tag in
                        Button {
                            if mergeSelection.contains(tag.id) {
                                mergeSelection.remove(tag.id)
                            } else {
                                mergeSelection.insert(tag.id)
                            }
                        } label: {
                            Text(tag.name)
                                .font(Theme.ui(11.5))
                                .foregroundStyle(
                                    mergeSelection.contains(tag.id)
                                        ? Theme.Text.onAmber : Theme.Text.tertiary)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 9)
                                .background(
                                    Capsule().fill(
                                        mergeSelection.contains(tag.id)
                                            ? Theme.Accent.amber : Color.clear))
                                .overlay(
                                    Capsule().stroke(
                                        mergeSelection.contains(tag.id)
                                            ? Theme.Accent.amber : Theme.Border.subtleButton,
                                        lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 9) {
                Button("Cancel") { self.keeperID = nil }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Spacer()
                Button("Keep both") { keepBoth() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Not Duplicates") { reject() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Send \u{201C}\(loser.fileName)\u{201D} to the delete list") {
                    decide(keeperID: keeperID, loserID: loser.id)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Surface.raised)
                .stroke(Theme.Border.standard, lineWidth: 1))
    }

    private func choose(_ id: UUID) {
        keeperID = id
        let loserID = id == itemA.id ? itemB.id : itemA.id
        do {
            mergeableTags = try model.library.mergeableTags(keeper: id, loser: loserID)
            mergeSelection = Set(mergeableTags.map(\.id))
            errorText = nil
        } catch {
            errorText = "\(error)"
        }
    }

    private func decide(keeperID: UUID, loserID: UUID) {
        do {
            let outcome = try model.library.decide(
                keeper: keeperID, loser: loserID,
                candidateID: candidate.id, mergeTagIDs: mergeSelection)
            var text = "Kept. \(outcome.tagsMerged) tags carried over."
            // The honest failure: a tag that could not carry because the
            // keeper already holds one in that single-value category.
            // Kept, and kept per tag.
            if !outcome.skippedSingleValue.isEmpty {
                text += " " + outcome.skippedSingleValue.joined(separator: " ")
            }
            outcomeText = text
            errorText = nil
            onResolved()
        } catch {
            errorText = "\(error)"
        }
    }

    private func reject() {
        do {
            try model.library.rejectCandidate(candidate.id)
            onResolved()
        } catch { errorText = "\(error)" }
    }

    private func keepBoth() {
        do {
            try model.library.keepBothCandidate(candidate.id)
            onResolved()
        } catch { errorText = "\(error)" }
    }
}

private struct ComparePane: View {
    @Environment(BrowseModel.self) private var model
    let item: MediaItem
    let other: MediaItem
    let isKeeper: Bool
    let isBestQuality: Bool
    let onKeep: () -> Void

    @State private var thumbnail: NSImage?

    private var score: QualityScoreResult { QualityScore.compute(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Surface.page)
                    .aspectRatio(16 / 9, contentMode: .fit)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                if isBestQuality {
                    ThemeBadge(
                        text: "best quality", fill: Theme.Status.goodBadgeFill,
                        foreground: Theme.Status.greenBright)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(7)
                }
            }
            Text(item.fileName)
                .font(Theme.ui(12.5, .semibold))
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            PathText(path: item.relativePath, size: 10)

            // Metric by metric, with the better value marked. The matcher
            // proposes; this is what it is proposing FROM.
            VStack(spacing: 2) {
                metric("Duration", value: item.durationSeconds, other: other.durationSeconds,
                       format: { $0.map(TransportBarTime.format) ?? "—" })
                metric("Size", value: Double(item.fileSize), other: Double(other.fileSize),
                       format: { $0.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—" })
                if item.kind == .video {
                    metric(
                        "Pixels",
                        value: item.width.flatMap { w in item.height.map { Double(w * $0) } },
                        other: other.width.flatMap { w in other.height.map { Double(w * $0) } },
                        format: { _ in "\(item.width ?? 0)×\(item.height ?? 0)" })
                }
                metric("Bitrate", value: item.bitrate.map(Double.init),
                       other: other.bitrate.map(Double.init),
                       format: { $0.map { "\(Int($0 / 1000)) kbps" } ?? "—" })
            }

            HStack(spacing: 6) {
                Text(String(format: "%.0f", score.total))
                    .font(Theme.mono(17, .bold))
                    .foregroundStyle(Theme.Text.primary)
                Text("/ 100")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Text.disabled)
            }
            ForEach(Array(score.components.enumerated()), id: \.offset) { _, component in
                HStack {
                    Text(component.label)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.disabled)
                    Spacer()
                    if component.maxPoints > 0 {
                        Text(String(format: "%.0f/%.0f", component.points, component.maxPoints))
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.Text.quaternary)
                    }
                }
                .help(component.note ?? "")
            }

            HStack {
                Button("Play") {
                    // The Review window swaps to the player in place
                    // (AuxiliaryWindowView), same pattern as the library
                    // window.
                    model.playerRequest = PlayerRequest(
                        libraryID: model.libraryID, itemID: item.id, playlist: [item.id])
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(!model.isOnline(item))
                Spacer()
                Button(isKeeper ? "Keeping this" : "Keep this", action: onKeep)
                    .buttonStyle(isKeeper ? AnyButtonStyleBox(PrimaryButtonStyle())
                        : AnyButtonStyleBox(SecondaryButtonStyle(compact: true)))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Surface.raised)
                .stroke(isKeeper ? Theme.Accent.amber : Theme.Border.standard, lineWidth: 1))
        .task(id: item.id) {
            let data = await ThumbnailProvider.shared.thumbnailData(
                itemID: item.id, libraryID: model.libraryID,
                fileURL: model.fileURL(for: item), durationSeconds: item.durationSeconds)
            thumbnail = data.flatMap(NSImage.init(data:))
        }
    }

    /// Higher is better for every metric here; the better value goes
    /// green and the other stays neutral rather than going red — one of
    /// them is going to be kept, and neither is wrong.
    private func metric(
        _ label: String, value: Double?, other: Double?, format: (Double?) -> String
    ) -> some View {
        let better = (value ?? 0) > (other ?? 0)
        return HStack {
            Text(label)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
            Spacer()
            Text(format(value))
                .font(Theme.mono(10.5))
                .foregroundStyle(better ? Theme.Status.green : Theme.Text.quaternary)
        }
    }
}

/// Type-erases a button style so one call site can choose between two.
private struct AnyButtonStyleBox: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { configuration in AnyView(style.makeBody(configuration: configuration)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
