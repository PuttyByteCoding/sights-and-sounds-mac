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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isNarrowed { filterStatus }
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

            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.filter.slottedTerms, id: \.term) { entry in
                    if let label = model.chipLabel(for: entry.term) {
                        statusRow(
                            mark: entry.slot.mark,
                            color: entry.slot.color,
                            text: "\(label.group) · \(label.value)",
                            strikethrough: entry.slot == .excluded,
                            help: entry.slot.legend
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
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.Surface.selectedRow)
                .stroke(Theme.Border.activeCard, lineWidth: 1))
        .padding(.bottom, 9)
    }

    /// One reason the listing is narrower, and the way to undo just that
    /// one — each row removes itself, so a filter can be unpicked a
    /// piece at a time rather than only cleared whole.
    private func statusRow(
        mark: String? = nil, symbol: String? = nil, color: Color, text: String,
        strikethrough: Bool = false, help: String, remove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Group {
                if let mark {
                    Text(mark).font(Theme.ui(10, .bold))
                } else if let symbol {
                    Image(systemName: symbol).font(Theme.ui(9))
                }
            }
            .foregroundStyle(color)
            .frame(width: 12)
            Text(text)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.secondary)
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
        .help(help)
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
            SidebarSectionLabel("Sources")
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
                        TagQueryField(text: query(for: entry.category.id))
                    }
                    ForEach(visibleTags(of: entry)) { tag in
                        TagFilterRow(tag: tag)
                    }
                    // Missing is a filter value like any other: required
                    // on Venue is the untagged worklist, excluded is
                    // "only fully tagged shows".
                    SlotRow(
                        term: .missingCategory(entry.category.id),
                        label: "Missing — no \(entry.category.name) tag",
                        count: model.counts.missingByCategory[entry.category.id] ?? 0,
                        italic: true)
                }
            }
            .padding(.top, 11)
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

    /// Three colours and three glyphs is more than a first-time user will
    /// infer, and the reverse step is invisible without being named.
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
            Text("Click cycles forward, right-click steps back.")
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
        guard !query.isEmpty else { return entry.tags }
        return entry.tags.filter { tag in
            model.filter.slot(of: tag.id) != nil
                || tag.name.localizedCaseInsensitiveContains(query)
                || (model.tagAliases[tag.id] ?? [])
                    .contains { $0.localizedCaseInsensitiveContains(query) }
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
    var secondaryAction: (() -> Void)?
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
            .modifier(SecondaryClick(action: secondaryAction))
    }

    private var background: Color {
        if let tint { return tint.opacity(0.08) }
        if selected { return Theme.Surface.selectedRow }
        return hovering ? Theme.Surface.raised : .clear
    }
}

/// Right-click, without a context menu. `onTapGesture` cannot see the
/// secondary button, so the reverse step comes from an AppKit gesture
/// recognizer's SwiftUI equivalent: a tap gesture bound to the right
/// mouse button.
private struct SecondaryClick: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.overlay(RightClickCatcher(action: action))
        } else {
            content
        }
    }
}

/// The right mouse button, caught by an AppKit view over the row.
/// SwiftUI has no secondary-click gesture; `contextMenu` is the only
/// built-in path to it and it opens a menu, which is precisely what the
/// reverse step must not do.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func rightMouseDown(with event: NSEvent) { action?() }
        // Transparent to everything except the secondary button, so the
        // forward cycle (a SwiftUI tap gesture underneath) is untouched —
        // including the control-click that AppKit already delivers as a
        // right mouse down.
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? self : nil
        }
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Theme.ui(9))
                .foregroundStyle(Theme.Text.disabled)
            TextField("Filter tags", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.secondary)
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

/// A tag row. Click cycles the slot forward, right-click steps it back —
/// and ⌥-click still opens the in-place editor (#108), which lost the
/// context menu to the reverse step.
private struct TagFilterRow: View {
    @Environment(BrowseModel.self) private var model
    let tag: Tag
    @State private var showEditor = false

    var body: some View {
        SlotRow(
            term: .tag(tag.id),
            label: tag.name,
            count: model.counts.byTag[tag.id] ?? 0,
            hidden: tag.hiddenByDefault,
            optionClick: { showEditor = true })
            .popover(isPresented: $showEditor, arrowEdge: .trailing) {
                TagEditorView(tag: tag)
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
    var italic = false
    var hidden = false
    var optionClick: (() -> Void)?

    var body: some View {
        let slot = model.filter.slot(of: term)
        SidebarRow(
            tint: slot?.color,
            action: {
                if let optionClick, NSEvent.modifierFlags.contains(.option) {
                    optionClick()
                } else {
                    model.filter.cycle(term)
                }
            },
            secondaryAction: { model.filter.cycle(term, reverse: true) }
        ) {
            FilterSlotChip(slot: slot)
            Text(label)
                .font(Theme.ui(12.5, slot == nil ? .regular : .medium))
                .italic(italic)
                .strikethrough(slot == .excluded)
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
        let base = "Click cycles forward, right-click steps back"
        return optionClick == nil ? base : base + ". ⌥-click to edit the tag"
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
