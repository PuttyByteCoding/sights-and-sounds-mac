import AppKit
import SwiftUI
import SightsAndSoundsKit

/// Tag analysis, wearing the comp's layout (`Mac Tag Analysis Window`):
/// left rail with the always-there preview, evidence-source and status
/// filters and this pass's tally; one candidate table in the centre with
/// the suggestion column carrying each row's classification; the decide
/// pane on the right.
///
/// The comp predates the per-video redesign, so its "deciding once
/// applies across every item" copy does NOT survive: analysis and
/// applying are per displayed video, accepts stage into the basket (in
/// the rail, under THIS PASS), and the ITEMS column shows a string's
/// library-wide reach as evidence of worth, not as blast radius.
struct TagAnalysisView: View {
    @Environment(BrowseModel.self) private var browse
    var queueIDs: [UUID] = []
    var startIndex: Int = 0
    @State private var model: TagAnalysisModel?
    @State private var rules: RulesTabModel?
    @State private var schemas: SchemasTabModel?
    @State private var mode: Mode = .candidates
    @FocusState private var focused: Bool

    enum Mode: String, Hashable { case candidates, rules, schemas }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let model, let rules {
                HSplitView {
                    RailView(model: model)
                        .frame(minWidth: 210, idealWidth: 240, maxWidth: 320)
                    switch mode {
                    case .candidates:
                        if model.showingReaderIO {
                            ReaderIOView(model: model)
                                .frame(minWidth: 620)
                        } else {
                            CandidateTable(model: model)
                                .frame(minWidth: 460)
                            DecidePane(model: model, onMakeRule: makeRule)
                                .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
                        }
                    case .rules:
                        RulesTabView(model: rules)
                    case .schemas:
                        if let schemas { SchemasTabView(model: schemas) }
                    }
                }
                if mode == .candidates {
                    QueueStrip(model: model)
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
        // punching through a focused text field as the player's do.
        // Advancing commits the basket; that is the contract.
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard let model else { return .ignored }
            if press.modifiers.contains(.shift),
               press.key == .leftArrow || press.key == .rightArrow
            {
                press.key == .leftArrow ? model.goPrevious() : model.goNext()
                return .handled
            }
            // Numpad transport is handled by the AppKit monitor below —
            // SwiftUI's key presses do not reliably carry the
            // numeric-pad flag, and top-row digits must NOT drive the
            // preview (they are separable from a filter field spelling
            // a tag name only when they stay out entirely).
            return .ignored
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
            schemas = SchemasTabModel(library: browse.library)
            focused = true
            sweepCurrentIfNeeded(made)
        }
        .onChange(of: model?.index ?? -1) { _, _ in
            if let model { sweepCurrentIfNeeded(model) }
        }
        .onDisappear {
            // Closing the window is the other way of leaving a video:
            // the basket lands and the visited marker is stamped.
            model?.commitBasket()
            model?.markCurrentAnalyzed()
        }
        // The numpad transport, at the AppKit layer. NSEvent's
        // numeric-pad flag is trustworthy where SwiftUI's is not, and a
        // local monitor sees keypad digits even while the filter field
        // owns the keyboard — the player's exception, kept exactly:
        // NUMPAD seeks mid-word; top-row digits never do.
        .background(NumpadTransportMonitor(handle: { character in
            model?.handlePreviewKey(character: character, shift: false, numpad: true) ?? false
        }))
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
            ThemeSegmentedControl(
                selection: $mode,
                options: [(.candidates, "Candidates"), (.rules, "Rules"), (.schemas, "Schemas")],
                emphasis: .neutral)
            if let model {
                Text(headline(model))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.Text.tertiary)
            }
            Spacer()
            if let model {
                HStack(spacing: 6) {
                    Text("⌕").font(Theme.ui(12)).foregroundStyle(Theme.Text.quaternary)
                    TextField(
                        "Filter values and keys",
                        text: Binding(get: { model.searchText }, set: { model.searchText = $0 }))
                        .textFieldStyle(.plain)
                        .font(Theme.ui(Theme.TypeScale.body))
                        .foregroundStyle(Theme.Text.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 240)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))

                Button("Scan On-Screen Text") {
                    // Vision OCR, on demand — deliberately never part of
                    // the automatic load (a full-video scan is minutes,
                    // not the seconds an advance can afford). Budgeted
                    // and resumable: a long video may take several
                    // clicks, each scanning further.
                    guard let id = model.currentItemID else { return }
                    model.beginSweep()
                    browse.scanText(itemID: id) { model.finishSweep() }
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(model.isLoading || model.currentItemID == nil)
                .help("Read on-screen text with Vision — resumable; click again to scan further")
                Button("Rescan This Video") {
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
        .padding(.vertical, 9)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private func headline(_ model: TagAnalysisModel) -> String {
        if model.isLoading { return "scanning…" }
        let strings = model.allRows.count
        let undecided = model.count(status: .undecided)
        return "\(strings) strings · \(undecided) undecided"
    }

    private func makeRule(key: String?, value: String) {
        guard let rules else { return }
        rules.makeRule(key: key, value: value)
        mode = .rules
    }
}

// MARK: - Left rail

/// PREVIEW · EVIDENCE SOURCES · STATUS · THIS PASS (with the basket).
/// The preview is always there, above the filters, per the comp — and
/// its ‹ › are the queue walk, so the rail is also the transport.
private struct RailView: View {
    @Environment(BrowseModel.self) private var browse
    let model: TagAnalysisModel
    @State private var previewCollapsed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview
                appliedBlock
                sources
                readerIO
                status
                thisPass
            }
            .padding(12)
        }
        .background(Theme.Surface.sidebar)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    previewCollapsed.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Text(previewCollapsed ? "›" : "⌄").font(Theme.ui(10))
                        Text("Preview").modifier(Theme.sectionLabel())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(model.index + 1) / \(model.queue.count)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Text.quaternary)
            }

            if !previewCollapsed {
                // A LIVE surface, not a still: the numpad transport
                // seeks and 5 plays right here, so "is that really the
                // taper's banner at 4:00?" is answerable without the
                // player window.
                // A small version of the player, not a still: the
                // surface plays, a click on it pauses and resumes, and
                // the strip below is a real scrubber.
                PlayerSurface(player: model.previewPlayer)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if model.previewBuffering {
                            ZStack {
                                Color.black.opacity(0.25)
                                ProgressView().controlSize(.small)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    .contentShape(Rectangle())
                    .onTapGesture { model.previewTogglePlay() }

                PreviewTransport(model: model)

                Text(model.currentItem?.fileName ?? "—")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Button("‹") { model.goPrevious() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .disabled(!model.canGoPrevious)
                        .help("Previous video — commits the basket (⇧←)")
                    Button("›") { model.goNext() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .disabled(!model.canGoNext)
                        .help("Next video — commits the basket (⇧→)")
                    Spacer()
                }
            }
        }
    }


    // MARK: Applied tags

    /// The tags the displayed video already wears, category-hued — the
    /// baseline for every decision. A basket commit or an advance
    /// refreshes it with the rest of the reload, so accepting a tag is
    /// visibly "it moved up here".
    @ViewBuilder
    private var appliedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Applied tags").modifier(Theme.sectionLabel())
                Spacer()
                Text("\(model.appliedTags.reduce(0) { $0 + $1.tags.count })")
                    .font(Theme.mono(10))
                    .foregroundStyle(
                        model.appliedTags.isEmpty
                            ? Theme.Text.zeroCount : Theme.Text.quaternary)
            }
            if model.appliedTags.isEmpty {
                Text("Nothing yet — that is what this window is for.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.quaternary)
            } else {
                ForEach(model.appliedTags, id: \.category.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.category.name)
                            .font(Theme.ui(10, .semibold))
                            .foregroundStyle(Theme.Text.tertiary)
                        FlowRow(spacing: 4) {
                            ForEach(entry.tags) { tag in
                                let hue = Theme.categoryHue(entry.category.colorIndex)
                                Text(tag.name)
                                    .font(Theme.ui(10.5))
                                    .foregroundStyle(hue)
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 7)
                                    .background(Capsule().fill(hue.opacity(0.13)))
                                    .overlay(Capsule().stroke(hue.opacity(0.35), lineWidth: 1))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Filters

    private static let sourceHues: [String: Color] = [
        "embeddedMetadata": Theme.Status.blueBright,
        "onScreen": Theme.Status.mauve,
        "path": Theme.Segment.song,
        "sidecarText": Theme.Status.orangeMuted,
        "sidecarJson": Theme.Status.green,
    ]

    private var sources: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Evidence sources").modifier(Theme.sectionLabel())
                .padding(.bottom, 4)
            sourceRow(nil, "All evidence")
            ForEach(LibraryDatabase.defaultAnalysisReaders(), id: \.id) { reader in
                sourceRow(reader.id, reader.displayName)
            }
        }
    }

    /// The Reader I/O page's rail entry — a sibling of Evidence Sources,
    /// because it answers the sibling question: sources say WHAT KIND of
    /// evidence, this says exactly what each reader put in and what
    /// came out.
    private var readerIO: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Reader I/O").modifier(Theme.sectionLabel())
                .padding(.bottom, 4)
            Button {
                model.showingReaderIO.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(Theme.ui(9))
                        .foregroundStyle(
                            model.showingReaderIO ? Theme.Accent.amber : Theme.Text.disabled)
                        .frame(width: 13)
                    Text("Raw in · processed out")
                        .font(Theme.ui(Theme.TypeScale.body,
                                       model.showingReaderIO ? .semibold : .regular))
                        .foregroundStyle(
                            model.showingReaderIO ? Theme.Text.primary : Theme.Text.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .fill(model.showingReaderIO ? Theme.Surface.selectedRow : .clear))
                .overlay(alignment: .leading) {
                    if model.showingReaderIO {
                        Rectangle().fill(Theme.Border.selectionInset)
                            .frame(width: Theme.Border.selectionInsetWidth)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show what each reader handed the pipeline, and what it became — click again for the candidates")
        }
    }

    private func sourceRow(_ readerID: String?, _ label: String) -> some View {
        let active = model.readerFilter == readerID
        let undecided = model.count(reader: readerID)
        return Button {
            model.readerFilter = readerID
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(readerID.flatMap { Self.sourceHues[$0] } ?? Theme.Text.disabled)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                        .font(Theme.ui(Theme.TypeScale.body, active ? .semibold : .regular))
                        .foregroundStyle(active ? Theme.Text.primary : Theme.Text.secondary)
                    Text("\(undecided) undecided")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(
                            undecided == 0 ? Theme.Text.zeroCount : Theme.Text.quaternary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(active ? Theme.Surface.selectedRow : .clear))
            .overlay(alignment: .leading) {
                if active {
                    Rectangle().fill(Theme.Border.selectionInset)
                        .frame(width: Theme.Border.selectionInsetWidth)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Status").modifier(Theme.sectionLabel())
                .padding(.bottom, 4)
            ForEach(TagAnalysisModel.StatusFilter.allCases, id: \.self) { filter in
                statusRow(filter)
            }
        }
    }

    private func statusRow(_ filter: TagAnalysisModel.StatusFilter) -> some View {
        let active = model.statusFilter == filter
        let count = model.count(status: filter)
        return Button {
            model.statusFilter = filter
        } label: {
            HStack(spacing: 7) {
                Circle().fill(statusHue(filter)).frame(width: 6, height: 6)
                Text(filter.label)
                    .font(Theme.ui(Theme.TypeScale.body, active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.Text.primary : Theme.Text.secondary)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(count == 0 ? Theme.Text.zeroCount : Theme.Text.quaternary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(active ? Theme.Surface.selectedRow : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusHue(_ filter: TagAnalysisModel.StatusFilter) -> Color {
        switch filter {
        case .undecided: Theme.Accent.amber
        case .inBasket: Theme.Status.green
        case .ignored: Theme.Text.disabled
        case .everything: Theme.Text.quaternary
        }
    }

    // MARK: This pass + basket

    private var thisPass: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This pass").modifier(Theme.sectionLabel())
            tally(model.tagsCommittedThisPass, "tags saved")
            tally(model.videosVisitedThisPass, "videos visited")

            if !model.basket.isEmpty {
                Text("Basket").modifier(Theme.sectionLabel(Theme.Accent.amber))
                    .padding(.top, 6)
                ForEach(model.basket) { pending in
                    HStack(spacing: 5) {
                        Text(pending.value)
                            .font(Theme.ui(Theme.TypeScale.secondary))
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let category = model.categories.first(where: { $0.id == pending.categoryID }) {
                            Text(category.name)
                                .font(Theme.ui(9.5))
                                .foregroundStyle(Theme.Text.quaternary)
                        }
                        Button("×") { model.unstage(pending.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(Theme.Surface.raised))
                }
                HStack(spacing: 6) {
                    Button("Save Now") { model.commitBasket() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    Button("Discard") { model.discardBasket() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                Text("Advancing saves the basket automatically.")
                    .font(Theme.ui(9.5))
                    .foregroundStyle(Theme.Text.quaternary)
            }
        }
    }

    private func tally(_ number: Int, _ label: String) -> some View {
        HStack(spacing: 7) {
            Text("\(number)")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(number == 0 ? Theme.Text.zeroCount : Theme.Accent.amber)
            Text(label)
                .font(Theme.ui(Theme.TypeScale.secondary))
                .foregroundStyle(Theme.Text.quaternary)
        }
    }
}

// MARK: - The table

private struct CandidateTable: View {
    let model: TagAnalysisModel

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            if !model.analysis.matchedSchemas.isEmpty {
                Text("Recognised: \(model.analysis.matchedSchemas.joined(separator: ", "))")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Status.greenBright)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Theme.Status.goodBadgeFill)
            }
            if model.analysis.truncated {
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
                    "Could Not Analyse", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if model.isLoading && model.allRows.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Reading everything that might describe this video…")
                        .font(Theme.ui(Theme.TypeScale.body))
                        .foregroundStyle(Theme.Text.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleRows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleRows) { row in
                            CandidateTableRow(model: model, row: row)
                        }
                    }
                }
            }
            FramesStrip(model: model)
        }
        .background(Theme.Surface.content)
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("Value").modifier(Theme.sectionLabel())
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Key").modifier(Theme.sectionLabel()).frame(width: 110, alignment: .leading)
            Text("Readers").modifier(Theme.sectionLabel()).frame(width: 96, alignment: .leading)
            Text("Seen").modifier(Theme.sectionLabel()).frame(width: 48, alignment: .trailing)
            Text("Suggestion").modifier(Theme.sectionLabel()).frame(width: 190, alignment: .leading)
            Text("").frame(width: 22)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(model.statusFilter == .undecided
                ? "Nothing left undecided" : "Nothing here")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.secondary)
            Text(model.statusFilter == .undecided
                ? "Every string from this video has been handled — advance to the next."
                : "Change the source or status filter to see more.")
                .font(Theme.ui(Theme.TypeScale.body))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CandidateTableRow: View {
    let model: TagAnalysisModel
    let row: TagAnalysisModel.TableRow

    private var candidate: AnalysisCandidate { row.candidate }
    private var isSelected: Bool { candidate.id == model.selectedCandidateID }

    var body: some View {
        Button {
            model.select(candidate.id)
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(candidate.value)
                        .font(Theme.ui(Theme.TypeScale.row))
                        .foregroundStyle(
                            candidate.suppressedByRule == nil
                                ? Theme.Text.primary : Theme.Text.disabled)
                        .strikethrough(
                            candidate.suppressedByRule != nil, color: Theme.Text.disabled)
                        .lineLimit(1)
                    if candidate.suppressedByRule != nil {
                        ThemeBadge(
                            text: "BY RULE", fill: Theme.Status.warnBadgeFill,
                            foreground: Theme.Status.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(candidate.key ?? "—")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.Text.quaternary)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)

                ReaderChips(origins: candidate.origins)
                    .frame(width: 96, alignment: .leading)

                Text("\(model.occurrenceCount(for: candidate))")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Text.secondary)
                    .frame(width: 48, alignment: .trailing)

                suggestionChip
                    .frame(width: 190, alignment: .leading)

                quickAccept
                    .frame(width: 22)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.Surface.selectedRow : .clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(Theme.Border.selectionInset)
                        .frame(width: Theme.Border.selectionInsetWidth)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var suggestionChip: some View {
        if model.status(of: row) == .inBasket {
            chip("In basket", Theme.Status.greenBright)
        } else if let category = candidate.category {
            chip("Assign to category · \(category)", Theme.Status.greenBright)
        } else if let finding = row.findings.first(where: { !$0.alreadyApplied }) {
            chip("Apply · \(finding.tag.name)", Theme.Status.blueBright)
        } else if row.findings.contains(where: \.alreadyApplied) {
            chip("Already applied", Theme.Text.quaternary)
        } else if candidate.suppressedByRule != nil {
            chip("Ignored", Theme.Text.disabled)
        } else {
            Text("—").font(Theme.ui(11)).foregroundStyle(Theme.Text.zeroCount)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.ui(10.5))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(color.opacity(0.13)))
    }

    /// The ⊕: take the row's own suggestion in one click — stage the
    /// mapped category, or apply the found tag. Rows with neither have
    /// nothing quick to do, and the button says so by its absence.
    @ViewBuilder
    private var quickAccept: some View {
        if model.status(of: row) != .inBasket {
            if let name = candidate.category, let category = model.category(named: name) {
                plusButton { model.stage(value: candidate.value, categoryID: category.id) }
            } else if let finding = row.findings.first(where: { !$0.alreadyApplied }) {
                plusButton { model.stage(finding) }
            }
        }
    }

    private func plusButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("⊕")
                .font(Theme.ui(13))
                .foregroundStyle(Theme.Accent.amber)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Take the suggestion — stages into the basket")
    }
}

// MARK: - Matching frames

/// The comp's strip, per video: stills of THIS video for the selected
/// string — the frame at the moment on-screen text was read.
private struct FramesStrip: View {
    @Environment(BrowseModel.self) private var browse
    let model: TagAnalysisModel
    @State private var hidden = false

    private var times: [Double] {
        guard let candidate = model.selectedCandidate else { return [] }
        return candidate.origins.compactMap(\.timeSeconds).sorted()
    }

    var body: some View {
        if !times.isEmpty, let item = model.currentItem,
           let fileURL = browse.fileURL(for: item)
        {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Matching frames").modifier(Theme.sectionLabel())
                    Text("the moment the text was read")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.disabled)
                    Spacer()
                    Button(hidden ? "Show" : "Hide") { hidden.toggle() }
                        .buttonStyle(.plain)
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.quaternary)
                }
                if !hidden {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(times.prefix(10), id: \.self) { seconds in
                                StripStill(itemID: item.id, fileURL: fileURL, seconds: seconds)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.Surface.toolbar)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }
        }
    }
}

private struct StripStill: View {
    let itemID: UUID
    let fileURL: URL
    let seconds: Double
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.Surface.stage)
                }
            }
            .frame(width: 116, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            Text(TransportBarTime.format(seconds))
                .font(Theme.mono(9))
                .foregroundStyle(Theme.Text.primary)
                .padding(.horizontal, 3)
                .background(Color.black.opacity(0.65))
                .padding(3)
        }
        .task(id: "\(itemID)-\(seconds)") {
            let data = await EvidenceFrameProvider.shared.frame(
                itemID: itemID, fileURL: fileURL, atSeconds: seconds)
            if let data { image = NSImage(data: data) }
        }
    }
}

// MARK: - Decide pane

/// CANDIDATE · DECIDE · CATEGORY · APPEARS IN, per the comp — with the
/// per-video difference that the primary button stages into the basket.
private struct DecidePane: View {
    let model: TagAnalysisModel
    let onMakeRule: (String?, String) -> Void

    @State private var editedValue = ""
    @State private var decision: Decision = .assign
    @State private var categoryID: UUID?
    @State private var aliasTargetID: UUID?
    /// The selected span headed into the New Tag sheet.
    @State private var newTagSeed: NewTagSeed?

    struct NewTagSeed: Identifiable {
        let text: String
        var id: String { text }
    }

    enum Decision: Hashable { case assign, applyExisting, alias, ignoreKey, hidePrefix }

    var body: some View {
        ScrollView {
            if let candidate = model.selectedCandidate {
                let row = model.allRows.first { $0.id == candidate.id }
                VStack(alignment: .leading, spacing: 14) {
                    candidateBlock(candidate)
                    decideBlock(candidate, findings: row?.findings ?? [])
                    if decision == .assign { categoryBlock }
                    appearsBlock(candidate)
                    primaryButton(candidate, findings: row?.findings ?? [])
                    Button("Make a rule from this…") {
                        onMakeRule(candidate.key, candidate.value)
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(candidate.id)
                .onAppear { seed(candidate, findings: row?.findings ?? []) }
                .sheet(item: $newTagSeed) { seedText in
                    if let fallback = categoryID ?? model.categories.first?.id {
                        TagSheet(
                            mode: .create(categoryID: fallback, name: seedText.text),
                            library: model.library,
                            libraryID: model.libraryID,
                            categories: model.categories
                        ) { tag in
                            // Creating from THIS video's evidence means
                            // tagging THIS video: the new tag goes into
                            // the basket, and the reload's existing-tag
                            // pass now recognises the string everywhere.
                            model.stage(
                                value: tag.name, categoryID: tag.tagCategoryID,
                                existingTagID: tag.id)
                            model.reload()
                        }
                    }
                }
            } else {
                Text("Select a string to decide what it is.")
                    .font(Theme.ui(Theme.TypeScale.body))
                    .foregroundStyle(Theme.Text.quaternary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .background(Theme.Surface.sidebar)
    }

    private func seed(_ candidate: AnalysisCandidate, findings: [ExistingTagFinding]) {
        editedValue = candidate.value
        categoryID = candidate.category.flatMap { model.category(named: $0)?.id }
        aliasTargetID = findings.first(where: { !$0.alreadyApplied })?.tag.id
        decision = candidate.category != nil
            ? .assign
            : findings.contains(where: { !$0.alreadyApplied }) ? .applyExisting : .assign
    }

    // MARK: Blocks

    private func candidateBlock(_ candidate: AnalysisCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Candidate").modifier(Theme.sectionLabel())
            // Editable in place — trim "tapper: " by hand — inside the
            // comp's bordered value box.
            TextField("", text: $editedValue)
                .textFieldStyle(.plain)
                .font(Theme.mono(14))
                .foregroundStyle(Theme.Accent.amber)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.activeCard, lineWidth: 1))
            Text(byline(candidate))
                .font(Theme.ui(Theme.TypeScale.secondary))
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // The raw text, selectable: drag a span, right-click, New
            // Tag — the path for "the taper's name is INSIDE this line".
            // The sheet's category picker decides where it lands.
            SelectableValueText(text: candidate.value) { selection in
                newTagSeed = NewTagSeed(text: selection)
            }
            .frame(height: candidate.value.count > 80 ? 72 : 40)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.Surface.well)
                    .stroke(Theme.Border.standard, lineWidth: 1))
            Text("Select text · right-click · New Tag")
                .font(Theme.ui(9.5))
                .foregroundStyle(Theme.Text.disabled)
        }
    }

    private func byline(_ candidate: AnalysisCandidate) -> String {
        if let schema = candidate.mappedBySchema {
            return "Mapped by schema “\(schema)”" + (candidate.key.map { " · key “\($0)”." } ?? ".")
        }
        // Names only what THIS video's evidence says — the sidecar file,
        // the key, the path, the screen. Library-wide reach was here and
        // removed on review: only information pulled from this video.
        let files = Set(candidate.origins.compactMap(\.sourceFile)).sorted()
        if let key = candidate.key {
            return "Found as metadata key “\(key)”."
        }
        if !files.isEmpty {
            return "Found in \(files.joined(separator: ", ")) beside this video."
        }
        if candidate.origins.contains(where: { $0.readerID == "path" }) {
            return "Found in this video's path."
        }
        if candidate.origins.contains(where: { $0.timeSeconds != nil }) {
            return "Read on screen in this video."
        }
        return "Found in this video's evidence."
    }

    private func decideBlock(
        _ candidate: AnalysisCandidate, findings: [ExistingTagFinding]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Decide").modifier(Theme.sectionLabel())
            radio(.assign, "Assign to a category",
                  "Creates the tag if needed and stages it for this video.")
            if let target = findings.first(where: { !$0.alreadyApplied }) {
                radio(.applyExisting, "Apply existing · \(target.tag.name)",
                      "The tag already exists in \(target.categoryName) — just apply it.")
                radio(.alias, "Add as an alias of \(target.tag.name)",
                      "Folds this spelling into the existing tag. Taggings are preserved.")
            }
            radio(.ignoreKey,
                  candidate.key == nil ? "Ignore this text" : "Ignore this key",
                  "Never offer it again — an ignore rule, reversible from the Rules tab.")
            if candidate.key == nil, candidate.origins.contains(where: { $0.readerID == "path" }) {
                radio(.hidePrefix, "Hide the prefix",
                      "Keeps deeper segments, drops this leading token — a hidePrefix rule.")
            }
        }
    }

    private func radio(_ value: Decision, _ title: String, _ note: String) -> some View {
        let active = decision == value
        return Button {
            decision = value
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(active ? Theme.Accent.amber : Theme.Surface.well)
                    .stroke(active ? Theme.Accent.amber : Theme.Border.raised, lineWidth: 1)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.ui(Theme.TypeScale.body, active ? .semibold : .regular))
                        .foregroundStyle(Theme.Text.primary)
                    Text(note)
                        .font(Theme.ui(Theme.TypeScale.secondary))
                        .foregroundStyle(Theme.Text.quaternary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(active ? Theme.Surface.selectedRow : .clear)
                    .stroke(active ? Theme.Border.activeCard : Theme.Border.standard, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var categoryBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Category").modifier(Theme.sectionLabel())
            ForEach(model.categories, id: \.id) { category in
                let active = categoryID == category.id
                Button {
                    categoryID = category.id
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Theme.categoryHue(category.colorIndex))
                            .frame(width: 6, height: 6)
                        Text(category.name)
                            .font(Theme.ui(Theme.TypeScale.body, active ? .semibold : .regular))
                            .foregroundStyle(Theme.Text.primary)
                        Spacer(minLength: 6)
                        Text(category.allowMultiple ? "multiple" : "one only")
                            .font(Theme.ui(9.5))
                            .foregroundStyle(Theme.Text.quaternary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(active ? Theme.Surface.selectedRow : .clear)
                            .stroke(
                                active ? Theme.Border.activeCard : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func appearsBlock(_ candidate: AnalysisCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Found in").modifier(Theme.sectionLabel())
            if candidate.trail.count > 1 || candidate.key != nil {
                // The road back: reader → each parsing step → the key.
                // "comment → jsonParser → taper" answers "where did this
                // come from" for a value three layers deep.
                Text(trailText(candidate))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Status.blueBright)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(originLines(candidate), id: \.self) { line in
                Text(line)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Text.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func trailText(_ candidate: AnalysisCandidate) -> String {
        var steps = candidate.trail.map { step in
            switch step {
            case "jsonParser": "JSON"
            case "pathParser": "path"
            default: step
            }
        }
        if let key = candidate.key, steps.last != key { steps.append("“\(key)”") }
        return steps.joined(separator: " → ")
    }

    /// One line per place in THIS video the string turned up.
    private func originLines(_ candidate: AnalysisCandidate) -> [String] {
        var lines: [String] = []
        for origin in candidate.origins {
            switch origin.readerID {
            case "embeddedMetadata":
                lines.append("embedded metadata\(candidate.key.map { " · \($0)" } ?? "")")
            case "path":
                lines.append(model.currentItem?.relativePath ?? "file path")
            case "onScreen":
                if let seconds = origin.timeSeconds {
                    lines.append("on screen at \(TransportBarTime.format(seconds))")
                }
            default:
                lines.append(origin.sourceFile ?? origin.readerID)
            }
        }
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    // MARK: The primary action

    @ViewBuilder
    private func primaryButton(
        _ candidate: AnalysisCandidate, findings: [ExistingTagFinding]
    ) -> some View {
        let target = findings.first { !$0.alreadyApplied }
        switch decision {
        case .assign:
            Button("Add to Basket") {
                guard let categoryID else { return }
                model.stage(value: editedValue, categoryID: categoryID)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(
                categoryID == nil
                    || editedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        case .applyExisting:
            Button("Apply to This Video") {
                if let target { model.stage(target) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(target == nil)
        case .alias:
            Button("Add Alias") {
                if let target { model.addAlias(editedValue, toTag: target.tag.id) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(target == nil || editedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        case .ignoreKey:
            Button(candidate.key == nil ? "Ignore This Text" : "Ignore This Key") {
                model.ignoreRule(for: candidate)
            }
            .buttonStyle(PrimaryButtonStyle())
        case .hidePrefix:
            Button("Hide the Prefix") {
                model.hidePrefixRule(root: candidate.value)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

// MARK: - Queue strip

/// The queue as thumbnails across the window's bottom — the walk made
/// visible. The current video wears the amber ring; a click is the same
/// commit-then-move as the arrows, and the strip follows the walk so
/// the current video is always in view.
private struct QueueStrip: View {
    @Environment(BrowseModel.self) private var browse
    let model: TagAnalysisModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(model.queue.enumerated()), id: \.element) { index, itemID in
                        QueueThumb(
                            itemID: itemID,
                            libraryID: model.libraryID,
                            library: model.library,
                            isCurrent: index == model.index,
                            onTap: { model.jump(to: index) })
                            .id(itemID)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(height: 92)
            .background(Theme.Surface.toolbar)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }
            .onChange(of: model.index) { _, _ in
                if let id = model.currentItemID {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .onAppear {
                if let id = model.currentItemID {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

private struct QueueThumb: View {
    let itemID: UUID
    let libraryID: UUID
    let library: LibraryDatabase
    let isCurrent: Bool
    let onTap: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.Surface.stage)
                }
            }
            .frame(width: 118, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .stroke(
                        isCurrent ? Theme.Accent.amber : Theme.Border.standard,
                        lineWidth: isCurrent ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: itemID) {
            guard thumbnail == nil else { return }
            let item = try? await library.writer.read { try MediaItem.fetchOne($0, key: itemID) }
            guard let item else { return }
            let fileURL = (try? library.resolvedFileURL(for: item)) ?? nil
            let data = await ThumbnailProvider.shared.thumbnailData(
                itemID: itemID, libraryID: libraryID, fileURL: fileURL,
                durationSeconds: item.durationSeconds)
            if let data { thumbnail = NSImage(data: data) }
        }
    }
}

// MARK: - Numpad monitor

/// A window-scoped AppKit key monitor for the preview transport.
///
/// SwiftUI's `KeyPress.modifiers` does not dependably include
/// `.numericPad` for keypad digits on macOS — the player never noticed
/// because bare digits reach the same table there. Here bare digits are
/// excluded on purpose, so the keypad must be told apart at the AppKit
/// layer, where the flag is reliable. The monitor only acts when its own
/// window is key, and swallows exactly the events it handled.
private struct NumpadTransportMonitor: NSViewRepresentable {
    let handle: (Character) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handle = handle
    }

    final class MonitorView: NSView {
        var handle: ((Character) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                // Leaving the window is the teardown path — SwiftUI
                // removes the representable from its window before
                // releasing it, so no deinit is needed (and a deinit
                // could not touch this main-actor state anyway).
                remove()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // Local key monitors fire on the main thread; say so
                    // to the compiler rather than leaving the closure's
                    // isolation to a toolchain's mood. Only a Bool
                    // crosses the boundary — NSEvent is not Sendable.
                    let handled = MainActor.assumeIsolated { () -> Bool in
                        guard let self, let window = self.window, event.window === window,
                              window.isKeyWindow,
                              event.modifierFlags.contains(.numericPad),
                              let character = event.charactersIgnoringModifiers?.first,
                              character.isNumber || character == "-"
                        else { return false }
                        return self.handle?(character) == true
                    }
                    return handled ? nil : event
                }
            }
        }

        private func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - Preview transport

/// The mini player's controls: play/pause, a click-and-drag scrubber,
/// and the timecode — the player window's transport, at rail scale.
/// Keyboard parity is already there (numpad seeks, 5 plays); this is
/// the pointer's half.
private struct PreviewTransport: View {
    let model: TagAnalysisModel

    var body: some View {
        HStack(spacing: 7) {
            Button {
                model.previewTogglePlay()
            } label: {
                Image(systemName: model.previewPlaying ? "pause.fill" : "play.fill")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.Text.primary)
                    .frame(width: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.previewPlaying ? "Pause (5)" : "Play (5)")

            GeometryReader { geometry in
                let width = geometry.size.width
                let fraction = model.previewDuration > 0
                    ? (model.previewSeconds / model.previewDuration).clamped01 : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Surface.well).frame(height: 4)
                    Capsule().fill(Theme.Accent.amber)
                        .frame(width: max(4, width * fraction), height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.previewSeek(toFraction: Double(value.location.x / width))
                        })
            }
            .frame(height: 14)

            Text("\(TransportBarTime.format(model.previewSeconds)) / \(TransportBarTime.format(model.previewDuration))")
                .font(Theme.mono(8.5))
                .foregroundStyle(Theme.Text.quaternary)
                .fixedSize()
        }
    }
}

// MARK: - Reader chips

/// Which reader(s) produced a value — compact, hue-matched to the rail's
/// evidence-source dots, with the sidecar's actual filename in the
/// tooltip.
private struct ReaderChips: View {
    let origins: [AnalysisOrigin]

    private static let short: [String: (label: String, hue: Color)] = [
        "embeddedMetadata": ("meta", Theme.Status.blueBright),
        "path": ("path", Theme.Segment.song),
        "sidecarText": ("txt", Theme.Status.orangeMuted),
        "sidecarJson": ("json", Theme.Status.green),
        "onScreen": ("ocr", Theme.Status.mauve),
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Set(origins.map(\.readerID))).sorted(), id: \.self) { readerID in
                let info = Self.short[readerID] ?? (readerID, Theme.Text.quaternary)
                Text(info.label)
                    .font(Theme.mono(8.5))
                    .foregroundStyle(info.hue)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(info.hue.opacity(0.12)))
                    .help(tooltip(readerID))
            }
        }
    }

    private func tooltip(_ readerID: String) -> String {
        let files = Set(
            origins.filter { $0.readerID == readerID }.compactMap(\.sourceFile)).sorted()
        let base = LibraryDatabase.defaultAnalysisReaders()
            .first { $0.id == readerID }?.displayName ?? readerID
        return files.isEmpty ? base : "\(base) — \(files.joined(separator: ", "))"
    }
}
