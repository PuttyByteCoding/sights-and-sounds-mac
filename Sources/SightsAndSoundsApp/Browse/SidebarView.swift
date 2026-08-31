import SwiftUI
import SightsAndSoundsKit

/// The browse sidebar: what is in the library, and what you are asking of
/// it. Media type, sources and their folder trees, the vocabulary as
/// three-way filter rows, the status flags, and the legend that explains
/// the three slots.
///
/// It paints its own surface (`#17130E` against the content's `#131009`)
/// rather than taking a system sidebar material — the app owns its
/// appearance, and the two surfaces differing is what lets the split need
/// no rule between them.
struct SidebarView: View {
    @Environment(BrowseModel.self) private var model

    // Tag categories start collapsed — the sidebar shows names, the user
    // opens what they filter by. Keyed by category id so vocabulary
    // refreshes don't reset what's open; resets with the window.
    @State private var expandedCategories: Set<UUID> = []
    // Folder trees, nested under their source rows, start collapsed too.
    @State private var expandedSources: Set<UUID> = []
    @State private var expandedFolders: Set<String> = []
    // Per-category tag-narrowing queries (view-only — never the media
    // filter). Keyed by category id, same lifetime as the sets above.
    @State private var tagQueries: [UUID: String] = [:]
    // What the sidebar said back when it refused a click.
    @State private var refusal: String?
    // How each category's tags are ordered. Session-scoped like the sets
    // above: which way you want a category sorted is a fact about the
    // hunt you are on, not about the library.
    @State private var tagSorts: [UUID: TagSort] = [:]

    /// The two orders a category's tags can take.
    enum TagSort: String, CaseIterable {
        case alphabetical, count

        var displayName: String {
            switch self {
            case .alphabetical: "Name"
            case .count: "Count"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned above the scroll, not inside it. This block is the
            // answer to "why am I seeing 12 items", and the moment that
            // question gets asked is the moment you have scrolled down
            // three categories looking for the thing that caused it.
            if isNarrowed {
                filterStatus
                    .padding(.horizontal, 8)
                    .padding(.top, 9)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    mediaTypeSection
                    sourcesSection
                    categorySections
                    statusSection
                    legend
                }
                .padding(.horizontal, 8)
                .padding(.top, 9)
                .padding(.bottom, 16)
            }
        }
        // The column's own surface, drawn edge to edge — including under
        // the toolbar, where a system material would otherwise show
        // through and put a seam across the top of the sidebar.
        .background { Theme.Surface.sidebar.ignoresSafeArea() }
    }

    // MARK: - Filter status

    /// Everything currently narrowing the listing, in one block at the
    /// top of the sidebar.
    ///
    /// It is deliberately wider than the chip bar over the grid. Chips
    /// are the three-way slots — the things you cycle. This also counts
    /// the reasons a listing is smaller that have no chip and no
    /// obviously visible control: the folder you clicked three
    /// disclosure triangles ago, the search text in a field at the other
    /// end of the window, and the offline items the banner is hiding.
    /// "Why am I seeing 12 items" is the question, and every answer to
    /// it belongs in one place.
    private var filterStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Filter").modifier(Theme.sectionLabel(Theme.Accent.amber))
                Spacer(minLength: 0)
                Button("Clear all") { clearEverything() }
                    .buttonStyle(.plain)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.quaternary)
                    .help("Clear the filter slots, the folder, the search text and the offline toggle")
            }

            // The count is the headline: visible against everything the
            // current media kinds could show.
            Text("\(model.visibleItems.count) of \(model.counts.total) items")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.secondary)

            // Pinning this block cost the tree height, and the cost grew
            // with every slot added — so the more you filtered, the less
            // tree you could see, which is backwards. Past three rows it
            // scrolls inside itself instead of pushing anything down.
            ScrollView {
                narrowingRows
            }
            .frame(maxHeight: Self.filterRowHeight * CGFloat(Self.filterRowsBeforeScroll))
            .scrollDisabled(narrowingRowCount <= Self.filterRowsBeforeScroll)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Surface.selectedRow)
                .stroke(Theme.Border.activeCard, lineWidth: 1))
        .padding(.bottom, 9)
    }

    /// How tall the pinned filter block is allowed to grow before it
    /// scrolls. Three rows: enough to read a typical filter at a glance,
    /// few enough that the tree underneath stays usable.
    private static let filterRowsBeforeScroll = 3
    private static let filterRowHeight: CGFloat = 25

    /// Everything currently narrowing the listing, one removable row each.
    private var narrowingRowCount: Int {
        model.filter.slottedTerms.count
            + (model.selectedFolderPath == nil ? 0 : 1)
            + (model.searchDisplayText.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1)
            + (model.hideOfflineItems ? 1 : 0)
    }

    @ViewBuilder private var narrowingRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(model.filter.slottedTerms, id: \.term) { entry in
                    if let label = model.chipLabel(for: entry.term) {
                        statusRow(
                            slot: entry.slot,
                            color: entry.slot.color,
                            text: "\(label.group) · \(label.value)",
                            strikethrough: entry.slot == .excluded,
                            help: entry.slot.legend,
                            cycle: { model.filter.cycle(entry.term) }
                        ) {
                            model.filter.setSlot(nil, for: entry.term)
                        }
                    }
                }
                if let folder = model.selectedFolderPath {
                    statusRow(
                        symbol: "folder",
                        color: Theme.Accent.amber,
                        text: folder.isEmpty ? "(root)" : folder,
                        help: "Only items in this folder and below"
                    ) {
                        model.selectFolder(nil)
                    }
                }
                if !model.searchDisplayText.trimmingCharacters(in: .whitespaces).isEmpty {
                    statusRow(
                        symbol: "magnifyingglass",
                        color: Theme.Status.blue,
                        text: "\u{201C}\(model.searchDisplayText)\u{201D}",
                        help: "Matches name, path, notes and on-screen text"
                    ) {
                        model.setSearchText("")
                    }
                }
                if model.hideOfflineItems {
                    statusRow(
                        symbol: "externaldrive.badge.xmark",
                        color: Theme.Status.orange,
                        text: "\(model.offlineItems.count) offline hidden",
                        help: "Items on an unplugged source are hidden from the listing"
                    ) {
                        model.hideOfflineItems = false
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One reason the listing is narrower, and the way to undo just that
    /// one — each row removes itself, so a filter can be unpicked a
    /// piece at a time rather than only cleared whole.
    /// A row carrying a `cycle` closure walks the slots on click, like
    /// the category rows that set them. The folder, search and offline
    /// rows have no slot to walk, so only their ✕ acts.
    private func statusRow(
        slot: MediaFilter.TagSlot? = nil, symbol: String? = nil, color: Color, text: String,
        strikethrough: Bool = false, help: String,
        cycle: (() -> Void)? = nil,
        remove: @escaping () -> Void
    ) -> some View {
        let content = HStack(spacing: 6) {
            Group {
                if let slot {
                    Text(slot.mark).font(Theme.ui(10, .bold))
                } else if let symbol {
                    Image(systemName: symbol).font(Theme.ui(9))
                }
            }
            .foregroundStyle(color)
            .frame(width: 12)
            Text(text)
                .font(Theme.ui(11.5))
                // Colour-coded: a slotted row reads as what it IS without
                // decoding a one-character glyph. The rows with no slot
                // stay neutral, so colour never means "nothing".
                .foregroundStyle(slot == nil ? Theme.Text.secondary : color)
                .strikethrough(strikethrough)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(Theme.ui(8))
                    .foregroundStyle(Theme.Text.disabled)
            }
            .buttonStyle(.plain)
        }
        return Group {
            if let cycle {
                SidebarRow(action: cycle) { content }
            } else {
                content
            }
        }
        .help(cycle == nil ? help : "\(help). Click to cycle.")
    }

    /// Anything at all narrowing the listing — the block appears only
    /// when there is something to explain.
    private var isNarrowed: Bool {
        !model.filter.slottedTerms.isEmpty
            || model.selectedFolderPath != nil
            || !model.searchDisplayText.trimmingCharacters(in: .whitespaces).isEmpty
            || model.hideOfflineItems
    }

    /// Clear all clears everything the block lists, including the two
    /// things `clearFilter` alone would leave behind.
    private func clearEverything() {
        model.clearFilter()
        model.hideOfflineItems = false
    }

    // MARK: - Media type

    /// Several kinds at once, and never none. The last selected kind
    /// refuses to turn off *and says so* — a click that silently does
    /// nothing reads as a bug.
    private var mediaTypeSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarSectionLabel("Media type")
            ForEach(MediaKind.allCases, id: \.self) { kind in
                KindRow(kind: kind, refusal: $refusal)
            }
            // Photos are designed for and not yet ingested: the row is
            // here so the plan is visible, and inert so it cannot lie.
            HStack(spacing: 8) {
                FilterCheckbox(isOn: false)
                Text("Photo")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.disabled)
                ThemeBadge(
                    text: "soon", fill: Theme.Surface.iconTile,
                    foreground: Theme.Text.disabled)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .help("Photo libraries are designed but not yet imported")
            if let refusal {
                Text(refusal)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Status.warnText)
                    .padding(.horizontal, 7)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 11)
        .animation(.easeOut(duration: 0.15), value: refusal)
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarSectionLabel("Browse Sources")
            SidebarRow(
                selected: model.selectedFolderPath == nil,
                action: { model.selectFolder(nil) }
            ) {
                Image(systemName: "square.grid.2x2")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.Text.disabled)
                    .frame(width: 13)
                Text("All Items")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.primary)
                Spacer(minLength: 0)
                CountText(model.counts.total)
            }
            ForEach(model.sources) { source in
                SourceRow(
                    source: source,
                    expanded: expandedSources.contains(source.id),
                    toggle: { toggle(source.id, in: &expandedSources) })
                if expandedSources.contains(source.id) {
                    FolderRows(
                        nodes: model.folderTrees[source.id] ?? [],
                        depth: 0, expanded: $expandedFolders)
                }
            }
            Button(action: addSource) {
                Text("+ Add Source…")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                    .padding(.vertical, 7)
                    .padding(.leading, 27)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Categories

    private var categorySections: some View {
        // The list's own header, above every category. Distinct from a
        // category's `sectionLabel`, which is a divider WITHIN the list —
        // this one names what the list is, the way "Browse Sources" and
        // "Media type" do above theirs.
        VStack(alignment: .leading, spacing: 0) {
            if !model.vocabulary.isEmpty {
                SidebarSectionLabel("Tag Categories")
            }
            ForEach(model.vocabulary) { entry in
            // A section label above a category: "" draws a plain divider,
            // text draws a labeled header (old browse-panel semantics).
            if let label = entry.category.sectionLabel {
                if label.isEmpty {
                    Divider()
                        .overlay(Theme.Border.standard)
                        .padding(.vertical, 7)
                } else {
                    SidebarSectionLabel(label)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                CategoryHeader(
                    entry: entry,
                    expanded: expandedCategories.contains(entry.category.id),
                    toggle: { toggle(entry.category.id, in: &expandedCategories) })
                if expandedCategories.contains(entry.category.id) {
                    if entry.tags.count > 8 {
                        HStack(spacing: 6) {
                            TagQueryField(
                                text: query(for: entry.category.id),
                                // With thousands of tags, typing is the
                                // only realistic way to find one — so the
                                // field takes the keyboard as it appears.
                                focusOnAppear: true)
                            sortMenu(for: entry.category.id)
                        }
                    }
                    // Missing is a filter value like any other: required
                    // on Venue is the untagged worklist, excluded is
                    // "only fully tagged shows".
                    //
                    // ABOVE the tags, not below them. It belongs to the
                    // category rather than to any tag in it, and under a
                    // category of three thousand it was a scroll box and
                    // then some distance further down — findable only if
                    // you already knew it was there.
                    missingRow(for: entry)
                    tagList(of: entry)
                }
            }
            .padding(.top, 11)
        }
        }
    }

    /// Name or count, per category. Only offered where the query field
    /// is — under nine tags the order is not a problem worth a control.
    private func sortMenu(for categoryID: UUID) -> some View {
        let current = tagSorts[categoryID] ?? .alphabetical
        return Menu {
            Picker("Sort", selection: Binding(
                get: { current },
                set: { tagSorts[categoryID] = $0 })
            ) {
                ForEach(TagSort.allCases, id: \.self) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: current == .count
                ? "arrow.down.circle" : "textformat.abc")
                .font(Theme.ui(10))
                .foregroundStyle(Theme.Text.disabled)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Order these tags by name or by how many items they hold")
    }

    /// "Missing — no <Category> tag": the items carrying nothing from
    /// this category. Filtered like the tags around it, so it narrows
    /// instead of standing still while everything else moves.
    private func missingRow(for entry: CategoryTags) -> some View {
        let unfiltered = model.counts.missingByCategory[entry.category.id] ?? 0
        let narrowed = model.filteredMissingCounts[entry.category.id]
        return SlotRow(
            term: .missingCategory(entry.category.id),
            label: "Missing — no \(entry.category.name) tag",
            count: narrowed ?? unfiltered,
            unfilteredCount: narrowed == nil ? nil : unfiltered,
            italic: true)
    }

    /// How many tag rows a category shows before the list gets its own
    /// scroll box, and how tall one row is.
    private static let tagRowsBeforeScroll = 20
    private static let tagRowHeight: CGFloat = 24

    /// The tag rows of an expanded category.
    ///
    /// Past `tagRowsBeforeScroll` they move into a fixed-height box built
    /// LAZILY — which is the half that matters. A category with 3,000
    /// tags was constructing 3,000 rows into the sidebar's scroll view on
    /// every expansion: the height was the visible symptom, the build was
    /// the slowness. A capped frame alone would have hidden the rows
    /// while still making all of them.
    ///
    /// Short categories stay inline. A scroll box around four rows is
    /// furniture for nothing.
    @ViewBuilder
    private func tagList(of entry: CategoryTags) -> some View {
        let tags = visibleTags(of: entry)
        if tags.count > Self.tagRowsBeforeScroll {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(tags) { TagFilterRow(tag: $0) }
                }
            }
            .frame(height: Self.tagRowHeight * CGFloat(Self.tagRowsBeforeScroll))
        } else {
            ForEach(tags) { TagFilterRow(tag: $0) }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarSectionLabel("Status")
            ForEach(StatusFlag.allCases, id: \.self) { flag in
                SlotRow(
                    term: .status(flag),
                    label: flag.displayName,
                    count: model.counts.byStatus[flag] ?? 0)
            }
        }
        .padding(.top, 11)
    }

    // MARK: - Legend

    /// Three colours and three glyphs is more than a first-time user
    /// will infer.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionLabel("Filter slots")
                .padding(.horizontal, 0)
            ForEach(MediaFilter.TagSlot.allCases, id: \.self) { slot in
                HStack(spacing: 7) {
                    FilterSlotChip(slot: slot, size: 13)
                    Text(slot.legend)
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.quaternary)
                }
            }
            Text("Click cycles through the slots. Right-click a tag to edit it.")
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.Text.disabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .padding(.horizontal, 9)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Border.standard)
                .frame(height: 1)
        }
        .padding(.top, 14)
    }

    // MARK: - Helpers

    private func toggle(_ id: UUID, in set: inout Set<UUID>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func query(for id: UUID) -> Binding<String> {
        Binding(
            get: { tagQueries[id, default: ""] },
            set: { tagQueries[id] = $0 })
    }

    /// The category's tags under its narrowing query. Name and alias
    /// match case-insensitively; a tag with an ACTIVE filter slot always
    /// stays visible, so a selection can never hide behind the query.
    private func visibleTags(of entry: CategoryTags) -> [Tag] {
        let query = tagQueries[entry.category.id, default: ""]
            .trimmingCharacters(in: .whitespaces)
        let matching: [Tag]
        if query.isEmpty {
            matching = entry.tags
        } else {
            matching = entry.tags.filter { tag in
                model.filter.slot(of: tag.id) != nil
                    || tag.name.localizedCaseInsensitiveContains(query)
                    || (model.tagAliases[tag.id] ?? [])
                        .contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        return sorted(matching, by: tagSorts[entry.category.id] ?? .alphabetical)
    }

    /// Tags a filter leaves nothing for sink to the bottom, whichever
    /// sort is chosen.
    ///
    /// That rule is not part of the sort, it is on top of it: down a list
    /// of thousands, "which of these still have videos" is the question,
    /// and the answer should not be scattered through the alphabet. A
    /// slotted tag never sinks — a tag you are actively filtering ON must
    /// stay where you can click it, even when it is the reason the count
    /// is zero.
    private func sorted(_ tags: [Tag], by sort: TagSort) -> [Tag] {
        let counts = model.filteredTagCounts
        guard !counts.isEmpty else {
            return sort == .count ? byCount(tags) : tags
        }
        func isEmpty(_ tag: Tag) -> Bool {
            model.filter.slot(of: tag.id) == nil && (counts[tag.id] ?? 0) == 0
        }
        let live = sort == .count ? byCount(tags.filter { !isEmpty($0) })
            : tags.filter { !isEmpty($0) }
        let spent = sort == .count ? byCount(tags.filter(isEmpty)) : tags.filter(isEmpty)
        return live + spent
    }

    /// Biggest first, ties broken by name so the order is total — an
    /// unstable sort down a long list reshuffles on every refresh.
    private func byCount(_ tags: [Tag]) -> [Tag] {
        let counts = model.filteredTagCounts
        func count(_ tag: Tag) -> Int {
            counts[tag.id] ?? model.counts.byTag[tag.id] ?? 0
        }
        return tags.sorted {
            let (a, b) = (count($0), count($1))
            return a == b
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : a > b
        }
    }
}

// MARK: - Section furniture

/// The 10px uppercase label above a group of rows.
private struct SidebarSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .modifier(Theme.sectionLabel())
            .padding(.horizontal, 7)
            .padding(.top, 5)
            .padding(.bottom, 6)
    }
}

/// Every clickable row in the sidebar: same padding, same radius, same
/// hover, one place.
private struct SidebarRow<Content: View>: View {
    var selected = false
    /// A slot's colour tints the row behind it.
    var tint: Color?
    var action: () -> Void
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5).fill(background))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
    }

    private var background: Color {
        if let tint { return tint.opacity(0.08) }
        if selected { return Theme.Surface.selectedRow }
        return hovering ? Theme.Surface.raised : .clear
    }
}

/// A count, in mono, dimmed to near-invisible at zero rather than
/// removed: a tag with no items under these kinds still exists (#96).
private struct CountText: View {
    let count: Int
    var size: CGFloat = 10.5
    init(_ count: Int, size: CGFloat = 10.5) {
        self.count = count
        self.size = size
    }

    var body: some View {
        Text("\(count)")
            .font(Theme.mono(size))
            .foregroundStyle(count == 0 ? Theme.Text.zeroCount : Theme.Text.disabled)
    }
}

/// The 14pt box in front of a media-type row.
private struct FilterCheckbox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.chip)
            .fill(isOn ? Theme.Accent.amber : .clear)
            .stroke(isOn ? Theme.Accent.amber : Theme.Border.subtleButtonHover, lineWidth: 1)
            .frame(width: 14, height: 14)
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(Theme.ui(9, .bold))
                        .foregroundStyle(Theme.Text.onAmber)
                }
            }
    }
}

// MARK: - Rows

private struct KindRow: View {
    @Environment(BrowseModel.self) private var model
    let kind: MediaKind
    @Binding var refusal: String?

    var body: some View {
        let on = model.kinds.contains(kind)
        SidebarRow(
            selected: on,
            action: {
                refusal = model.toggleKind(kind)
                    ? nil : "At least one media type stays selected"
            }
        ) {
            FilterCheckbox(isOn: on)
            Text(kind.displayName)
                .font(Theme.ui(12.5, on ? .medium : .regular))
                .foregroundStyle(on ? Theme.Text.primary : Theme.Text.quaternary)
            Spacer(minLength: 0)
            // Counted across every kind, so an unselected row still says
            // what is behind it.
            CountText(model.counts.byKind[kind] ?? 0)
        }
    }
}

/// The narrowing field at the top of an expanded category — filters
/// which tag rows are SHOWN, never the media query itself.
private struct TagQueryField: View {
    @Binding var text: String
    /// Expanding a category is a statement of intent to find one tag in
    /// it. Taking the keyboard here means the next keystroke narrows the
    /// list instead of falling through to the grid's single-key map.
    var focusOnAppear = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Theme.ui(9))
                .foregroundStyle(Theme.Text.disabled)
            TextField("Filter tags", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.secondary)
                .focused($focused)
                .onAppear { if focusOnAppear { focused = true } }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.disabled)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.Surface.well)
                .stroke(Theme.Border.standard, lineWidth: 1))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
    }
}

private struct SourceRow: View {
    @Environment(BrowseModel.self) private var model
    let source: Source
    let expanded: Bool
    let toggle: () -> Void
    @State private var renaming = false

    var body: some View {
        // Sidebar convention: clicking a collapsible header's name
        // toggles it — the whole row, not just the chevron.
        SidebarRow(action: toggle) {
            Chevron(expanded: expanded)
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(source.name)
                .font(Theme.ui(12.5))
                .foregroundStyle(source.enabled ? Theme.Text.primary : Theme.Text.disabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if let status = model.importStatus[source.id] {
                Text(status)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Accent.amber)
            } else if !source.enabled {
                ThemeBadge(
                    text: "disabled", fill: Theme.Surface.iconTile,
                    foreground: Theme.Text.disabled)
            } else if !model.onlineSourceIDs.contains(source.id) {
                ThemeBadge(
                    text: "offline", fill: Theme.Status.warnBadgeFill,
                    foreground: Theme.Status.orange)
            }
            Spacer(minLength: 0)
            CountText(model.counts.bySource[source.id] ?? 0, size: 11)
        }
        .contextMenu {
            Button("Import New Files") { model.importSource(source) }
                .disabled(!source.enabled
                    || !model.onlineSourceIDs.contains(source.id)
                    || model.importStatus[source.id] != nil)
            Button(source.enabled ? "Disable" : "Enable") {
                model.setSourceEnabled(source, !source.enabled)
            }
            Divider()
            // A rename is a label change and nothing else — the library
            // keys off the source's id and finds files by its path — so
            // it sits with the harmless entries rather than behind a
            // confirmation.
            Button("Rename…") { renaming = true }
        }
        .sheet(isPresented: $renaming) {
            SourceRenameSheet(source: source) { model.renameSource(source, to: $0) }
        }
        .help(source.rootPath)
    }

    private var statusColor: Color {
        if !source.enabled { return Theme.Text.disabled }
        return model.onlineSourceIDs.contains(source.id)
            ? Theme.Status.green : Theme.Status.orange
    }
}

/// One source's folder tree, nested. Recursive rather than an
/// `OutlineGroup` because every row here is painted from the tokens.
private struct FolderRows: View {
    @Environment(BrowseModel.self) private var model
    let nodes: [FolderNode]
    let depth: Int
    @Binding var expanded: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            SidebarRow(
                selected: model.selectedFolderPath == node.path,
                action: { model.selectFolder(node.path) }
            ) {
                if node.children.isEmpty {
                    Color.clear.frame(width: 9)
                } else {
                    Chevron(expanded: expanded.contains(node.path))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if expanded.contains(node.path) {
                                expanded.remove(node.path)
                            } else {
                                expanded.insert(node.path)
                            }
                        }
                }
                Text(node.name)
                    .font(Theme.ui(12))
                    .foregroundStyle(
                        model.selectedFolderPath == node.path
                            ? Theme.Accent.amber : Theme.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                CountText(node.subtreeCount)
            }
            .padding(.leading, CGFloat(depth) * 12 + 20)
            if expanded.contains(node.path), !node.children.isEmpty {
                FolderRows(nodes: node.children, depth: depth + 1, expanded: $expanded)
            }
        }
    }
}

private struct Chevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(Theme.ui(9))
            .foregroundStyle(Theme.Text.disabled)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 9)
            .animation(.easeOut(duration: 0.12), value: expanded)
    }
}

private struct CategoryHeader: View {
    @Environment(BrowseModel.self) private var model
    let entry: CategoryTags
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        SidebarRow(action: toggle) {
            Chevron(expanded: expanded)
            // The category's stored hue, not one invented here.
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.categoryHue(entry.category.colorIndex))
                .frame(width: 6, height: 6)
            Text("\(entry.category.name) (\(entry.tags.count))")
                .modifier(Theme.sectionLabel())
            Spacer(minLength: 0)
            // A collapsed category must still signal live selections —
            // a filter can't hide invisibly.
            if !expanded, activeSlots > 0 {
                Text("\(activeSlots)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Accent.amber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.Surface.iconTileSelected))
            }
        }
    }

    private var activeSlots: Int {
        entry.tags.count { model.filter.slot(of: $0.id) != nil }
            + (model.filter.slot(of: .missingCategory(entry.category.id)) != nil ? 1 : 0)
    }
}

/// A tag row. Click cycles the slot; right-click edits the tag. The
/// reverse step used to own right-click and the editor was an ⌥-click
/// nobody could discover — trading one for the other gives the editor
/// the gesture people actually reach for.
private struct TagFilterRow: View {
    @Environment(BrowseModel.self) private var model
    let tag: Tag
    @State private var showEditor = false
    @State private var showCompany = false

    var body: some View {
        // Filtered count while a filter is on — "if I added this, how
        // many would survive" — and the library-wide count otherwise.
        let unfiltered = model.counts.byTag[tag.id] ?? 0
        let narrowed = model.filteredTagCounts[tag.id]
        SlotRow(
            term: .tag(tag.id),
            label: tag.name,
            count: narrowed ?? unfiltered,
            unfilteredCount: narrowed == nil ? nil : unfiltered,
            hidden: tag.hiddenByDefault)
            // Right-click is free now that it no longer steps the cycle
            // backwards, and a context menu is where anyone looks for
            // "edit this" — ⌥-click was a chord you had to be told about.
            .contextMenu {
                Button("Edit Tag…") { showEditor = true }
                Button("Show Items with This Tag") { showCompany = true }
            }
            .sheet(isPresented: $showCompany) {
                TagItemsSheet(
                    tag: tag,
                    categoryName: model.vocabulary
                        .first { $0.category.id == tag.tagCategoryID }?.category.name,
                    library: model.library, libraryID: model.libraryID)
            }
            .sheet(isPresented: $showEditor) {
                TagSheet(
                    mode: .edit(tag),
                    library: model.library,
                    libraryID: model.libraryID,
                    categories: model.vocabulary.map(\.category),
                    onSaved: { _ in model.refreshAll() })
            }
    }
}

/// Any row that carries a filter slot: a tag, a `Missing — no <Category>
/// tag` row, a status flag. One row type, because they behave
/// identically and a second implementation is a second set of bugs.
private struct SlotRow: View {
    @Environment(BrowseModel.self) private var model
    let term: FilterTerm
    let label: String
    let count: Int
    /// What this row counts when nothing is filtered, for the tooltip.
    /// Non-nil only when `count` is the narrowed number, so the row can
    /// say "12 of 70" on hover without spending sidebar width on it.
    var unfilteredCount: Int?
    var italic = false
    var hidden = false

    var body: some View {
        let slot = model.filter.slot(of: term)
        SidebarRow(
            tint: slot?.color,
            action: { model.filter.cycle(term) },
        ) {
            FilterSlotChip(slot: slot)
            Text(label)
                .font(Theme.ui(12.5, slot == nil ? .regular : .medium))
                .italic(italic)
                // Struck when excluded, and struck when the current
                // filter leaves it nothing — both mean "this row will
                // not give you items", which is the thing worth seeing
                // at a glance down a long list.
                .strikethrough(slot == .excluded || (unfilteredCount != nil && count == 0))
                .foregroundStyle(nameColor(slot))
                .lineLimit(1)
                .truncationMode(.middle)
            if hidden {
                Image(systemName: "eye.slash")
                    .font(Theme.ui(9))
                    .foregroundStyle(Theme.Text.disabled)
            }
            Spacer(minLength: 0)
            CountText(count)
        }
        .help(helpText)
    }

    private func nameColor(_ slot: MediaFilter.TagSlot?) -> Color {
        switch slot {
        case .excluded: Theme.Text.quaternary
        case .some: Theme.Text.primary
        case nil: italic ? Theme.Text.quaternary : Theme.Text.secondary
        }
    }

    private var helpText: String {
        var parts: [String] = []
        // The narrowing lives here rather than on the row: the sidebar is
        // narrow and one category can run to thousands of rows, so a
        // second number on every line is noise exactly where it is least
        // affordable.
        if let unfilteredCount {
            parts.append(
                count == unfilteredCount
                    ? "\(count) items — the filter takes none of them away"
                    : "\(count) of \(unfilteredCount) items survive the current filter")
        }
        parts.append("Click cycles through required, optional and excluded")
        parts.append("right-click to edit the tag")
        return parts.joined(separator: ". ")
    }
}

extension SidebarView {
    fileprivate func addSource() {
        let panel = NSOpenPanel()
        panel.title = "Add Source Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Add Source"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addSource(at: url)
    }
}

/// Rename one source.
///
/// Its own small sheet rather than an inline edit in the row: the row is
/// a click target that toggles a folder tree, and an editable field
/// inside it would make every rename start with a mis-click.
private struct SourceRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: Source
    let onRename: (String) -> Void

    @State private var name: String
    @FocusState private var focused: Bool

    init(source: Source, onRename: @escaping (String) -> Void) {
        self.source = source
        self.onRename = onRename
        _name = State(initialValue: source.name)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Rename Source")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.primary)

            TextField("", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(
                            focused ? Theme.Border.activeControl : Theme.Border.standard,
                            lineWidth: focused ? 2 : 1))
                .focused($focused)

            // The path, because two sources can honestly share a name and
            // this is the half that says which one you are renaming.
            PathText(path: source.rootPath, size: 10.5)

            Text("Enter saves · Esc to cancel")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Save") { commit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(trimmed.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(Theme.Surface.dialog)
        .onKeyPress { press in
            if press.key == .escape {
                dismiss()
                return .handled
            }
            return .ignored
        }
        .onAppear { focused = true }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
        dismiss()
    }
}
