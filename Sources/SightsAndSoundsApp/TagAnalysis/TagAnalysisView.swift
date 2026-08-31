import AppKit
import SwiftUI
import SightsAndSoundsKit

/// Tag analysis — the window, and the switch between its two modes.
///
/// The Candidates side is a per-video triage surface: every place
/// metadata might live for the DISPLAYED video — embedded fields, JSON
/// inside them, the path, sidecar text and JSON files, on-screen text —
/// analysed into three buckets: rule-mapped suggestions, existing tags
/// found in the evidence, and unmapped text for judgment. Accepted tags
/// stage into a basket that commits when you advance.
///
/// Candidates is triage, Rules is automation, and §4 is the hinge
/// between them: deciding the same thing twice is a rule waiting to be
/// written, so "Make a rule from this" carries the string across rather
/// than asking for it again.
struct TagAnalysisView: View {
    @Environment(BrowseModel.self) private var browse
    /// The queue this window walks, and where in it to start — the same
    /// listing the player takes, iterated with the same SHIFT+arrows.
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
        // Advancing commits the basket; that is the contract.
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
            if let model { sweepCurrentIfNeeded(model) }
        }
        // Closing the window is the third way of saying "done with this
        // one" — the basket commits rather than evaporating.
        .onDisappear { model?.commitBasket() }
    }

    /// Each video sweeps on display when the metadata sweep has not
    /// reached it — "no metadata yet, wait for the library pass" is an
    /// empty window with no explanation. Checked first, so an
    /// already-swept video queues nothing.
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

    /// The queue walk: which video is on display, where it sits, the
    /// arrows — mirroring the player's transport reading of the same
    /// queue.
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
            .help("Previous video — commits the basket (⇧←)")

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
            .help("Next video — commits the basket (⇧→)")
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
    private func makeRule(key: String?, value: String) {
        guard let rules else { return }
        rules.makeRule(key: key, value: value)
        mode = .rules
    }
}

// MARK: - Candidates

private struct CandidatesTab: View {
    let model: TagAnalysisModel
    let onMakeRule: (String?, String) -> Void

    var body: some View {
        HSplitView {
            buckets
                .frame(minWidth: 480)
            VStack(spacing: 0) {
                DetailPane(model: model, onMakeRule: onMakeRule)
                BasketPanel(model: model)
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
            .background(Theme.Surface.sidebar)
        }
    }

    private var buckets: some View {
        VStack(spacing: 0) {
            searchBar
            if model.analysis.truncated {
                // Where the results are, not only in a trail — an
                // incomplete list that looks complete is worse than a
                // visibly incomplete one.
                Text("Analysis ran out of time — these results are incomplete.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Status.warnText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Theme.Status.warnBadgeFill)
            }
            if let error = model.loadError {
                ContentUnavailableView(
                    "Could Not Analyse",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if model.isLoading && model.analysis == .empty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Reading everything that might describe this video…")
                        .font(Theme.ui(Theme.TypeScale.body))
                        .foregroundStyle(Theme.Text.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if !model.visibleSuggested.isEmpty {
                            Section(header: bucketHeader(
                                "Suggested", "a rule mapped these")) {
                                ForEach(model.visibleSuggested) { candidate in
                                    SuggestedRow(model: model, candidate: candidate)
                                }
                            }
                        }
                        if !model.visibleExisting.isEmpty {
                            Section(header: bucketHeader(
                                "Existing tags found", "nothing to create — just apply")) {
                                ForEach(model.visibleExisting) { finding in
                                    ExistingRow(model: model, finding: finding)
                                }
                            }
                        }
                        Section(header: bucketHeader(
                            "Unmapped text", "everything else — your judgment")) {
                            if model.visibleUnmapped.isEmpty {
                                Text("Nothing unmapped.")
                                    .font(Theme.ui(Theme.TypeScale.secondary))
                                    .foregroundStyle(Theme.Text.quaternary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            ForEach(model.visibleUnmapped) { candidate in
                                UnmappedRow(model: model, candidate: candidate)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Theme.Surface.content)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Text("⌕").font(Theme.ui(12)).foregroundStyle(Theme.Text.quaternary)
            TextField(
                "Filter this video's strings",
                text: Binding(get: { model.searchText }, set: { model.searchText = $0 }))
                .textFieldStyle(.plain)
                .font(Theme.ui(Theme.TypeScale.body))
                .foregroundStyle(Theme.Text.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private func bucketHeader(_ title: String, _ hint: String) -> some View {
        HStack(spacing: 8) {
            Text(title).modifier(Theme.sectionLabel())
            Text(hint)
                .font(Theme.ui(10))
                .foregroundStyle(Theme.Text.disabled)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.Surface.content)
    }
}

// MARK: - Rows

private struct SuggestedRow: View {
    let model: TagAnalysisModel
    let candidate: AnalysisCandidate

    var body: some View {
        HStack(spacing: 8) {
            RowSelectTarget(model: model, candidate: candidate) {
                HStack(spacing: 6) {
                    Text(candidate.value)
                        .font(Theme.ui(Theme.TypeScale.row))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(1)
                    if let key = candidate.key { KeyChip(key: key) }
                    OriginChips(origins: candidate.origins)
                }
            }
            Spacer(minLength: 6)
            if let name = candidate.category { ThemeBadge(text: name.uppercased()) }
            stageButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(candidate.id == model.selectedCandidateID ? Theme.Surface.selectedRow : .clear)
    }

    @ViewBuilder
    private var stageButton: some View {
        let category = candidate.category.flatMap { model.category(named: $0) }
        if category == nil {
            // The rule names a category the library does not have — say
            // so instead of a button that silently cannot work.
            Text("no such category")
                .font(Theme.ui(10))
                .foregroundStyle(Theme.Status.warnText)
        } else if model.isStaged(value: candidate.value, categoryID: category?.id) {
            Text("in basket")
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.Status.greenBright)
        } else {
            Button("Accept") {
                if let category { model.stage(value: candidate.value, categoryID: category.id) }
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
        }
    }
}

private struct ExistingRow: View {
    let model: TagAnalysisModel
    let finding: ExistingTagFinding

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(finding.tag.name)
                        .font(Theme.ui(Theme.TypeScale.row, .medium))
                        .foregroundStyle(
                            finding.alreadyApplied ? Theme.Text.quaternary : Theme.Text.primary)
                        .strikethrough(finding.alreadyApplied, color: Theme.Text.quaternary)
                    if finding.matchedText.caseInsensitiveCompare(finding.tag.name) != .orderedSame {
                        Text("(\(finding.matchedText))")
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.Text.quaternary)
                    }
                    ThemeBadge(
                        text: finding.categoryName.uppercased(),
                        fill: Theme.Surface.iconTile, foreground: Theme.Status.blueBright)
                }
                Text("found in “\(finding.foundIn)”")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if finding.alreadyApplied {
                Text("already applied")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.quaternary)
            } else if model.isStaged(tagID: finding.tag.id) {
                Text("in basket")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Status.greenBright)
            } else {
                Button("Apply") { model.stage(finding) }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct UnmappedRow: View {
    let model: TagAnalysisModel
    let candidate: AnalysisCandidate

    var body: some View {
        HStack(spacing: 8) {
            RowSelectTarget(model: model, candidate: candidate) {
                HStack(spacing: 6) {
                    Text(candidate.value)
                        .font(Theme.ui(Theme.TypeScale.row))
                        .foregroundStyle(
                            candidate.suppressedByRule == nil
                                ? Theme.Text.secondary : Theme.Text.disabled)
                        .strikethrough(candidate.suppressedByRule != nil, color: Theme.Text.disabled)
                        .lineLimit(1)
                    if let key = candidate.key { KeyChip(key: key) }
                    OriginChips(origins: candidate.origins)
                    if let rule = candidate.suppressedByRule {
                        Text("ignored — \(rule)")
                            .font(Theme.ui(9.5))
                            .foregroundStyle(Theme.Status.orange)
                    }
                }
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(candidate.id == model.selectedCandidateID ? Theme.Surface.selectedRow : .clear)
    }
}

/// The clickable body of a candidate row — selection fills the detail
/// pane, where the value gets edited and judged.
private struct RowSelectTarget<Content: View>: View {
    let model: TagAnalysisModel
    let candidate: AnalysisCandidate
    @ViewBuilder let content: Content

    var body: some View {
        Button {
            model.selectedCandidateID = candidate.id
        } label: {
            content.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct KeyChip: View {
    let key: String
    var body: some View {
        Text(key)
            .font(Theme.mono(9.5))
            .foregroundStyle(Theme.Status.blueBright)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(Theme.Status.blueBright.opacity(0.12)))
    }
}

private struct OriginChips: View {
    let origins: [AnalysisOrigin]

    private static let names: [String: String] = [
        "embeddedMetadata": "metadata", "path": "path", "sidecarText": "txt",
        "sidecarJson": "json", "onScreen": "on-screen",
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Set(origins.map(\.readerID))).sorted(), id: \.self) { readerID in
                Text(Self.names[readerID] ?? readerID)
                    .font(Theme.ui(8.5, .bold))
                    .foregroundStyle(Theme.Text.quaternary)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(Theme.Surface.iconTile))
            }
        }
    }
}

// MARK: - Detail pane

/// Judgment happens here: the selected string, its value editable —
/// trim "tapper: " by hand, fix casing — a category, and Add to Basket.
private struct DetailPane: View {
    @Environment(BrowseModel.self) private var browse
    let model: TagAnalysisModel
    let onMakeRule: (String?, String) -> Void

    @State private var editedValue = ""
    @State private var categoryID: UUID?

    var body: some View {
        ScrollView {
            if let candidate = model.selectedCandidate {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Candidate").modifier(Theme.sectionLabel())
                    TextField("", text: $editedValue)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(Theme.TypeScale.dialogTitle))
                        .foregroundStyle(Theme.Text.primary)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 9)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(Theme.Surface.well)
                                .stroke(Theme.Border.standard, lineWidth: 1))

                    if let key = candidate.key {
                        Text("Found under the key “\(key)”")
                            .font(Theme.ui(Theme.TypeScale.secondary))
                            .foregroundStyle(Theme.Text.tertiary)
                    }

                    Picker("", selection: $categoryID) {
                        Text("Choose a category…").tag(UUID?.none)
                        ForEach(model.categories, id: \.id) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                    .labelsHidden()

                    Button("Add to Basket") {
                        guard let categoryID else { return }
                        model.stage(value: editedValue, categoryID: categoryID)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(
                        categoryID == nil
                            || editedValue.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Make a rule from this…") {
                        onMakeRule(candidate.key, candidate.value)
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))

                    // Spec 14 §8, per video: for on-screen text, the
                    // frame AT THE MOMENT the string was read — the only
                    // reason a still is worth showing.
                    let times = candidate.origins.compactMap(\.timeSeconds)
                    if !times.isEmpty, let item = model.currentItem,
                       let fileURL = browse.fileURL(for: item) {
                        Text("Read on screen at").modifier(Theme.sectionLabel())
                        ForEach(times.sorted().prefix(3), id: \.self) { seconds in
                            OcrStill(itemID: item.id, fileURL: fileURL, seconds: seconds)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(candidate.id)
                .onAppear {
                    editedValue = candidate.value
                    categoryID = candidate.category
                        .flatMap { model.category(named: $0)?.id }
                }
            } else {
                Text("Select a string to edit it and add it as a tag.")
                    .font(Theme.ui(Theme.TypeScale.body))
                    .foregroundStyle(Theme.Text.quaternary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
    }
}

// MARK: - Basket

/// The tags staged for THIS video. Committed by advance, Save, or the
/// window closing; Discard drops them. The count is in the header line
/// so an advance never silently commits more than you think.
private struct BasketPanel: View {
    let model: TagAnalysisModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Basket").modifier(Theme.sectionLabel())
                Text("\(model.basket.count)")
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(
                        model.basket.isEmpty ? Theme.Text.zeroCount : Theme.Accent.amber)
                Spacer()
                Text("\(model.tagsCommittedThisPass) saved this pass")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.quaternary)
            }

            if model.basket.isEmpty {
                Text("Accepted tags collect here, and are written when you advance.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.quaternary)
            } else {
                ForEach(model.basket) { pending in
                    HStack(spacing: 6) {
                        TextField(
                            "",
                            text: Binding(
                                get: { pending.value },
                                set: { model.updateStaged(pending.id, value: $0) }))
                            .textFieldStyle(.plain)
                            .font(Theme.ui(Theme.TypeScale.body))
                            .foregroundStyle(Theme.Text.primary)
                        if let category = model.categories.first(where: { $0.id == pending.categoryID }) {
                            Text(category.name)
                                .font(Theme.ui(10))
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                        Button("×") { model.unstage(pending.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(Theme.Surface.raised))
                }
                HStack(spacing: 8) {
                    Button("Save Now") { model.commitBasket() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    Button("Discard") { model.discardBasket() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(maxHeight: 300)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }
}


/// One frame, seeked to when the text was read — EvidenceFrameProvider
/// seeks tight (±0.5s), because a frame the text is not on answers
/// nothing.
private struct OcrStill: View {
    let itemID: UUID
    let fileURL: URL
    let seconds: Double
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Theme.Surface.stage).frame(height: 90)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            Text(TransportBarTime.format(seconds))
                .font(Theme.mono(9))
                .foregroundStyle(Theme.Text.primary)
                .padding(.horizontal, 3)
                .background(Color.black.opacity(0.65))
                .padding(4)
        }
        .task(id: "\(itemID)-\(seconds)") {
            let data = await EvidenceFrameProvider.shared.frame(
                itemID: itemID, fileURL: fileURL, atSeconds: seconds)
            if let data { image = NSImage(data: data) }
        }
    }
}
