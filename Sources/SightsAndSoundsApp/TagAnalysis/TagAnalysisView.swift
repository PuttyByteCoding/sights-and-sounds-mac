import AppKit
import SwiftUI
import SightsAndSoundsKit

/// Tag analysis — the window, and the switch between its two modes.
///
/// Candidate mining across the library: strings that appear in items with
/// no tag behind them, triaged in one place. This is the **plural half of
/// what the player does one item at a time** (spec 14 §2): the player can
/// copy an on-screen line, make a tag from it or add it as an alias for
/// the item playing; everything that touches *other* items happens here.
/// That one rule is what stops the same feature being built twice.
///
/// Candidates is triage, Rules is automation, and §4 is the hinge
/// between them: deciding the same thing twice is a rule waiting to be
/// written, so "Make a rule from this" carries the string across rather
/// than asking for it again.
struct TagAnalysisView: View {
    @Environment(BrowseModel.self) private var browse
    /// The queue this window walks, and where in it to start. Analysis is
    /// always one video at a time — the window exists to iterate the
    /// queue the way the player does, SHIFT+arrows included.
    var queueIDs: [UUID] = []
    var startIndex: Int = 0
    @State private var model: TagAnalysisModel?
    @State private var rules: RulesTabModel?
    @State private var mode: Mode = .candidates
    @FocusState private var focused: Bool

    enum Mode: String, Hashable { case candidates, rules }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let model {
                switch mode {
                case .candidates:
                    CandidatesTab(model: model, onMakeRule: makeRule)
                case .rules:
                    if let rules { RulesTabView(model: rules) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1_100, minHeight: 620)
        .background(Theme.Surface.content)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // SHIFT+arrows walk the queue, the player's gesture exactly —
        // and like the player's, they punch through a focused text field
        // (extending a selection by one character is the only cost).
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard press.modifiers.contains(.shift),
                  press.key == .leftArrow || press.key == .rightArrow,
                  let model
            else { return .ignored }
            press.key == .leftArrow ? model.goPrevious() : model.goNext()
            return .handled
        }
        .task {
            guard model == nil else { return }
            // The queue comes with the request; an empty one falls back
            // to whatever the hosting window is listing, so a stale
            // restored window still opens on something real.
            let queue = queueIDs.isEmpty ? browse.visibleItems.map(\.id) : queueIDs
            let made = TagAnalysisModel(
                library: browse.library, libraryID: browse.libraryID,
                queue: queue, startAt: startIndex)
            made.reload()
            model = made
            rules = RulesTabModel(library: browse.library)
            focused = true
            sweepCurrentIfNeeded(made)
        }
        .onChange(of: model?.index ?? -1) { _, _ in
            // Each video sweeps on display, not on demand: the analysis
            // is FOR the video being shown, and "no metadata yet, wait
            // for the library pass" is an empty window with no
            // explanation. Checked first, so an already-swept video
            // queues nothing.
            if let model { sweepCurrentIfNeeded(model) }
        }
    }

    private func sweepCurrentIfNeeded(_ model: TagAnalysisModel) {
        guard let id = model.currentItemID,
              (try? browse.library.unsweptCount(in: [id])) ?? 0 > 0
        else { return }
        model.beginSweep()
        browse.sweepMetadata(itemIDs: [id]) { model.finishSweep() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Tag Analysis").modifier(Theme.sectionLabel(Theme.Accent.amber))
            ThemeSegmentedControl(
                selection: $mode,
                options: [(.candidates, "Candidates"), (.rules, "Rules")],
                emphasis: .neutral)
            Spacer()
            if let model {
                queueControls(model)
                Text(model.isLoading ? "Scanning…" : "\(model.candidates.count) candidates")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Text.quaternary)
                Button("Rescan This Video") {
                    // Re-probe on purpose, so the marker clears first —
                    // otherwise the sweep skips a video it has already
                    // visited, and the button does nothing.
                    guard let id = model.currentItemID else { return }
                    try? browse.library.resetMetadataSweep(itemIDs: [id])
                    model.beginSweep()
                    browse.sweepMetadata(itemIDs: [id]) { model.finishSweep() }
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(model.isLoading || model.currentItemID == nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    /// The queue walk: which video is on display, where it sits in the
    /// queue, and the arrows — mirroring the player's transport reading
    /// of the same queue.
    @ViewBuilder
    private func queueControls(_ model: TagAnalysisModel) -> some View {
        HStack(spacing: 8) {
            Button {
                model.goPrevious()
            } label: {
                Image(systemName: "chevron.left").font(Theme.ui(11, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canGoPrevious ? Theme.Text.secondary : Theme.Text.disabled)
            .disabled(!model.canGoPrevious)
            .help("Previous video in the queue (⇧←)")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.currentItem?.fileName ?? "—")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
                Text("\(model.index + 1) of \(model.queue.count) in the queue")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.quaternary)
            }

            Button {
                model.goNext()
            } label: {
                Image(systemName: "chevron.right").font(Theme.ui(11, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canGoNext ? Theme.Text.secondary : Theme.Text.disabled)
            .disabled(!model.canGoNext)
            .help("Next video in the queue (⇧→)")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                .fill(Theme.Surface.iconTileSelected))
    }

    /// Spec 14 §4 — the entire path from one-off triage to automation,
    /// and it must not require retyping the string. If a rule already
    /// covers the candidate this OPENS that rule rather than adding a
    /// rival, which is why the tab switch happens either way.
    private func makeRule(from candidate: TagCandidate) {
        guard let rules else { return }
        rules.makeRule(from: candidate)
        mode = .rules
    }
}

// MARK: - Candidates

private struct CandidatesTab: View {
    @Environment(BrowseModel.self) private var browse
    let model: TagAnalysisModel
    let onMakeRule: (TagCandidate) -> Void

    var body: some View {
        HSplitView {
            rail
                .frame(minWidth: 212, idealWidth: 244, maxWidth: 470)
            VStack(spacing: 0) {
                table
                if !model.picked.isEmpty { bulkBar }
                if model.selected != nil { EvidenceStrip(model: model) }
            }
            .frame(minWidth: 420)
            DetailPane(model: model, onMakeRule: onMakeRule)
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
        }
    }

    // MARK: Left rail

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchField

                section("Evidence sources") {
                    filterRow(.all, count: model.candidates.count)
                    ForEach(TagCandidateSource.allCases, id: \.self) { source in
                        filterRow(.source(source), count: model.count(for: .source(source)))
                    }
                }

                section("Status") {
                    ForEach(TagAnalysisModel.StatusFilter.allCases, id: \.self) { status in
                        statusRow(status)
                    }
                }

                section("This pass") {
                    tally("\(model.acceptedThisPass)", "accepted")
                    tally("\(model.ignoredThisPass)", "ignored")
                    if model.lastDecision != nil {
                        Button("Undo last decision") { model.undoLastDecision() }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                            .padding(.top, 4)
                    }
                }
            }
            .padding(14)
        }
        .background(Theme.Surface.sidebar)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Text("⌕").font(Theme.ui(12)).foregroundStyle(Theme.Text.quaternary)
            TextField("Search candidates", text: Binding(
                get: { model.searchText }, set: { model.searchText = $0 }))
                .textFieldStyle(.plain)
                .font(Theme.ui(Theme.TypeScale.body))
                .foregroundStyle(Theme.Text.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Surface.well)
                .stroke(Theme.Border.standard, lineWidth: 1))
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).modifier(Theme.sectionLabel())
            content()
        }
    }

    private func filterRow(_ filter: TagAnalysisModel.SourceFilter, count: Int) -> some View {
        let active = model.sourceFilter == filter
        return Button {
            model.sourceFilter = filter
        } label: {
            HStack(spacing: 8) {
                Text(filter.label)
                    .font(Theme.ui(Theme.TypeScale.body, active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.Text.primary : Theme.Text.secondary)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(Theme.mono(11))
                    // Dimmed, not hidden: "this source exists but has
                    // nothing left" is the information.
                    .foregroundStyle(count == 0 ? Theme.Text.zeroCount : Theme.Text.quaternary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(rowBackground(active))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusRow(_ status: TagAnalysisModel.StatusFilter) -> some View {
        let active = model.statusFilter == status
        return Button {
            // Clicking the active one clears it — the filter is optional,
            // and there is no "all statuses" row to return to.
            model.statusFilter = active ? nil : status
        } label: {
            HStack(spacing: 8) {
                Text(status.label)
                    .font(Theme.ui(Theme.TypeScale.body, active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.Text.primary : Theme.Text.secondary)
                Spacer(minLength: 6)
                Text("\(model.count(for: status))")
                    .font(Theme.mono(11))
                    .foregroundStyle(
                        model.count(for: status) == 0
                            ? Theme.Text.zeroCount : Theme.Text.quaternary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(rowBackground(active))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowBackground(_ active: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.chip)
            .fill(active ? Theme.Surface.selectedRow : .clear)
    }

    private func tally(_ number: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.Text.primary)
            Text(label).font(Theme.ui(Theme.TypeScale.secondary))
                .foregroundStyle(Theme.Text.quaternary)
        }
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            columnHeader
            if let error = model.loadError {
                ContentUnavailableView(
                    "Could Not Build the Queue",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if model.visible.isEmpty {
                emptyQueue
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visible) { candidate in
                            CandidateRow(
                                candidate: candidate,
                                isSelected: candidate.id == model.selectedID,
                                isPicked: model.picked.contains(candidate.id),
                                onSelect: { model.select(candidate) },
                                onTogglePick: { model.togglePicked(candidate) })
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("").frame(width: 18)
            Text("Value").modifier(Theme.sectionLabel())
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Key").modifier(Theme.sectionLabel()).frame(width: 140, alignment: .leading)
            Text("Items").modifier(Theme.sectionLabel()).frame(width: 54, alignment: .trailing)
            Text("Suggestion").modifier(Theme.sectionLabel()).frame(width: 128, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var emptyQueue: some View {
        VStack(spacing: 6) {
            Text("Nothing left in this queue")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.secondary)
            Text("Every candidate from this source has been decided.")
                .font(Theme.ui(Theme.TypeScale.body))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bulk bar

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text("\(model.picked.count) picked · \(model.itemsAffected) items affected")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.Text.secondary)
            Spacer()
            Button("Apply suggestions") { model.applyPickedSuggestions() }
                .buttonStyle(PrimaryButtonStyle())
                // A pick with no suggestion between them has nothing to
                // apply, and the button says so by being unavailable
                // rather than by silently doing nothing.
                .disabled(!model.pickedCandidates.contains { model.suggestedCategory(for: $0) != nil })
            Button("Ignore") { model.ignorePicked() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            Button("Make a rule") {
                // From the first pick: a rule is authored from ONE string,
                // and the matcher it starts with generalises from there.
                if let first = model.pickedCandidates.first { onMakeRule(first) }
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            Button("Clear") { model.clearPicks() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }
}

// MARK: - Row

private struct CandidateRow: View {
    let candidate: TagCandidate
    let isSelected: Bool
    let isPicked: Bool
    let onSelect: () -> Void
    let onTogglePick: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTogglePick) {
                Text(isPicked ? "✓" : "")
                    .font(Theme.ui(11, .bold))
                    .foregroundStyle(Theme.Accent.amber)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(isPicked ? Theme.Surface.iconTileSelected : Theme.Surface.well)
                            .stroke(Theme.Border.standard, lineWidth: 1))
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                sourceChip
                Text(candidate.value)
                    .font(Theme.ui(Theme.TypeScale.row))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                if candidate.suppressedByRule != nil {
                    // Struck, not hidden. A mis-authored ignore rule has
                    // to be diagnosable rather than invisible — the row
                    // stays and says which rule did it.
                    ThemeBadge(
                        text: "BY RULE", fill: Theme.Status.warnBadgeFill,
                        foreground: Theme.Status.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(candidate.key ?? "—")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.quaternary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            Text("\(candidate.itemCount)")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.Text.secondary)
                .frame(width: 54, alignment: .trailing)

            HStack(spacing: 4) {
                if let category = candidate.suggestedCategory {
                    ThemeBadge(text: category.uppercased())
                } else {
                    Text("—").font(Theme.ui(11)).foregroundStyle(Theme.Text.zeroCount)
                }
                if candidate.coveredByRuleID != nil {
                    Text("✓").font(Theme.ui(11)).foregroundStyle(Theme.Status.green)
                        .help("Already covered by a rule — showing it")
                }
            }
            .frame(width: 128, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Theme.Spacing.rowVertical - 2)
        .background(isSelected ? Theme.Surface.selectedRow : .clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.Border.selectionInset)
                    .frame(width: Theme.Border.selectionInsetWidth)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var sourceChip: some View {
        Text(candidate.source.displayName)
            .font(Theme.ui(9, .bold))
            .foregroundStyle(chipColor)
            .padding(.vertical, 1.5)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(chipColor.opacity(0.14)))
    }

    private var chipColor: Color {
        switch candidate.source {
        case .metadata: Theme.Status.blueBright
        case .onScreen: Theme.Status.mauve
        case .path: Theme.Segment.song
        }
    }
}

// MARK: - Detail pane

private struct DetailPane: View {
    @Environment(BrowseModel.self) private var browse
    let model: TagAnalysisModel
    let onMakeRule: (TagCandidate) -> Void
    @State private var targetCategoryID: UUID?

    var body: some View {
        ScrollView {
            if let candidate = model.selected {
                VStack(alignment: .leading, spacing: 16) {
                    header(candidate)
                    decide(candidate)
                    appearsIn(candidate)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Rebuild the target when the candidate changes, so a
                // category chosen for one string never silently carries
                // over to the next.
                .id(candidate.id)
                .onAppear { targetCategoryID = model.suggestedCategory(for: candidate)?.id }
            } else {
                Text("Select a candidate to see where it appears and what to do with it.")
                    .font(Theme.ui(Theme.TypeScale.body))
                    .foregroundStyle(Theme.Text.quaternary)
                    .multilineTextAlignment(.center)
                    .padding(28)
            }
        }
        .background(Theme.Surface.sidebar)
    }

    private func header(_ candidate: TagCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Candidate").modifier(Theme.sectionLabel())
            Text(candidate.value)
                .font(Theme.ui(Theme.TypeScale.windowHeading, .semibold))
                .foregroundStyle(Theme.Text.primary)
                .textSelection(.enabled)
            Text(summary(candidate))
                .font(Theme.ui(Theme.TypeScale.secondary))
                .foregroundStyle(Theme.Text.tertiary)
            if let rule = candidate.suppressedByRule {
                Text("A rule would drop this — \(rule). Showing it anyway.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Status.warnText)
            }
        }
    }

    private func summary(_ candidate: TagCandidate) -> String {
        let where_ = candidate.key.map { "\(candidate.source.displayName) · \($0)" }
            ?? candidate.source.displayName
        return "\(where_) · \(candidate.itemCount) item\(candidate.itemCount == 1 ? "" : "s")"
    }

    private func decide(_ candidate: TagCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Decide").modifier(Theme.sectionLabel())

            Picker("", selection: $targetCategoryID) {
                Text("Choose a category…").tag(UUID?.none)
                ForEach(model.categories, id: \.id) { category in
                    Text(category.name).tag(UUID?.some(category.id))
                }
            }
            .labelsHidden()
            .font(Theme.ui(Theme.TypeScale.body))

            Button("Make a tag in this category") {
                guard let targetCategoryID else { return }
                model.apply(candidate, .assignCategory(categoryID: targetCategoryID))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(targetCategoryID == nil)

            Button("Ignore this candidate") {
                model.apply(candidate, .ignore)
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))

            Button("Make a rule from this…") { onMakeRule(candidate) }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            if candidate.coveredByRuleID != nil {
                Text("Already covered by a rule — showing it")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.quaternary)
            }

            Text("Applying writes tags to \(candidate.itemCount) item\(candidate.itemCount == 1 ? "" : "s"), revertible from the tag history.")
                .font(Theme.ui(Theme.TypeScale.secondary))
                .foregroundStyle(Theme.Text.quaternary)
        }
    }

    private func appearsIn(_ candidate: TagCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Appears in").modifier(Theme.sectionLabel())
            if model.evidence.isEmpty {
                Text("No reachable items — the source may be offline.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.quaternary)
            } else {
                ForEach(model.evidence.prefix(12)) { one in
                    PathText(path: one.item.relativePath)
                }
                if candidate.itemCount > model.evidence.count {
                    Text("and \(candidate.itemCount - model.evidence.count) more")
                        .font(Theme.ui(Theme.TypeScale.secondary))
                        .foregroundStyle(Theme.Text.quaternary)
                }
            }
        }
    }
}

// MARK: - Evidence strip

/// One still per matching item — for on-screen text, the frame **at the
/// moment the string was read** (spec 14 §8). That is the only reason a
/// still is worth showing: it answers "is this really a band name?"
/// without opening ten items.
private struct EvidenceStrip: View {
    @Environment(BrowseModel.self) private var browse
    let model: TagAnalysisModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Matching frames").modifier(Theme.sectionLabel())
                Spacer()
                Text(label)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Text.quaternary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.evidence.prefix(12)) { one in
                        EvidenceThumb(
                            evidence: one,
                            fileURL: browse.fileURL(for: one.item),
                            libraryID: model.libraryID)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: 132)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var label: String {
        let shown = min(model.evidence.count, 12)
        guard let selected = model.selected else { return "" }
        return shown < selected.itemCount
            ? "\(shown) of \(selected.itemCount)" : "\(shown)"
    }
}

private struct EvidenceThumb: View {
    let evidence: CandidateEvidence
    let fileURL: URL?
    let libraryID: UUID
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.Surface.stage)
                }
            }
            .frame(width: 116, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .overlay(alignment: .bottomTrailing) {
                if let seconds = evidence.timeSeconds {
                    Text(timecode(seconds))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.Text.primary)
                        .padding(.horizontal, 3)
                        .background(Color.black.opacity(0.65))
                        .padding(3)
                }
            }

            Text(evidence.item.relativePath)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.Text.quaternary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 116, alignment: .leading)
        }
        .task(id: evidence.id) { await load() }
    }

    private func load() async {
        guard let fileURL else { return }
        let data: Data?
        if let seconds = evidence.timeSeconds {
            data = await EvidenceFrameProvider.shared.frame(
                itemID: evidence.item.id, fileURL: fileURL, atSeconds: seconds)
        } else {
            // No moment to seek to — a metadata or path candidate is a
            // property of the file, so the grid thumbnail is the honest
            // still rather than a frame at zero.
            data = await ThumbnailProvider.shared.thumbnailData(
                itemID: evidence.item.id, libraryID: libraryID, fileURL: fileURL,
                durationSeconds: evidence.item.durationSeconds)
        }
        if let data { image = NSImage(data: data) }
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
