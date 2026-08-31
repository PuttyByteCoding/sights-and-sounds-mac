import SwiftUI
import SightsAndSoundsKit

/// One thing the palette can do.
///
/// Every command's name is **the name it already has** — from the grid's
/// context menu, from a window title, from the browse filter row. The
/// palette must not paraphrase, or it becomes a second vocabulary for
/// the same actions.
struct PaletteCommand: Identifiable {
    enum Group: String, CaseIterable {
        case goTo, filter, tag, `do`, view

        var heading: String {
            switch self {
            case .goTo: "GO TO"
            case .filter: "FILTER"
            case .tag: "TAG THE SELECTION"
            case .do: "DO"
            case .view: "VIEW"
            }
        }

        /// Typing a group's name narrows to it.
        var searchWord: String {
            switch self {
            case .goTo: "go to"
            case .filter: "filter"
            case .tag: "tag"
            case .do: "do"
            case .view: "view"
            }
        }
    }

    /// Stable, and generated from the title once — recents store ids, so
    /// writing them by hand in two places is how they drift.
    var id: String
    var group: Group
    var title: String
    var symbol: String
    var keyEquivalent: String?
    /// How many items must be selected. The command is still listed
    /// without them, greyed, with the requirement where its description
    /// goes.
    var requiresSelection: Int = 0
    /// A command that drills: the ellipsis means it.
    var arguments: (() -> [PaletteCommand])?
    var run: () -> Void

    init(
        group: Group, title: String, symbol: String, keyEquivalent: String? = nil,
        requiresSelection: Int = 0,
        arguments: (() -> [PaletteCommand])? = nil,
        run: @escaping () -> Void
    ) {
        self.id = "\(group.rawValue):\(title.lowercased())"
        self.group = group
        self.title = title
        self.symbol = symbol
        self.keyEquivalent = keyEquivalent
        self.requiresSelection = requiresSelection
        self.arguments = arguments
        self.run = run
    }

    /// A command that only drills does nothing on its own.
    init(
        group: Group, title: String, symbol: String, requiresSelection: Int = 0,
        arguments: @escaping () -> [PaletteCommand]
    ) {
        self.init(
            group: group, title: title, symbol: symbol,
            requiresSelection: requiresSelection, arguments: arguments, run: {})
    }

    var drills: Bool { arguments != nil }
}

/// ⌃K over the library window: one field reaching windows, filters,
/// tagging, operations and saved tile views — so a command used twice a
/// year does not need a menu anyone can find.
struct CommandPalette: View {
    @Environment(BrowseModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var highlighted = 0
    /// One level of drill. Escape steps back before it closes, so a
    /// wrong turn costs one key.
    @State private var drilled: PaletteCommand?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider().overlay(Theme.Border.standard)
            results
            legend
        }
        .frame(width: 620, height: 460)
        .background(Theme.Surface.dialog)
        .onExitCommand {
            // Escape steps back one level before it closes.
            if drilled != nil {
                drilled = nil
                query = ""
            } else if !query.isEmpty {
                query = ""
            } else {
                dismiss()
            }
        }
        .onAppear { fieldFocused = true }
        // ↑↓ move the highlight while the field keeps the keyboard —
        // typing and choosing are the same gesture here.
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlighted = min(max(0, visible.count - 1), highlighted + 1)
            return .handled
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let drilled {
                HStack(spacing: 5) {
                    Text(drilled.title)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Accent.amber)
                    Text("›")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.disabled)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(14))
                    .foregroundStyle(Theme.Text.primary)
                    .focused($fieldFocused)
                    .onChange(of: query) { highlighted = 0 }
                    .onSubmit { runHighlighted() }
            }
        }
        .padding(14)
    }

    private var placeholder: String {
        drilled.map { "Pick a \($0.title.replacingOccurrences(of: "…", with: ""))" }
            ?? "Search commands, tags and windows…"
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if visible.isEmpty {
                        Text(query.isEmpty
                            ? "Commands, windows, filters and your own tag names — all from this one field."
                            : "Tag names, category names and every window are searchable from here.")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.Text.disabled)
                            .padding(16)
                    }
                    ForEach(PaletteCommand.Group.allCases, id: \.self) { group in
                        let rows = visible.filter { $0.group == group }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { command in
                                    row(command)
                                        .id(command.id)
                                }
                            } header: {
                                Text(group.heading)
                                    .modifier(Theme.sectionLabel())
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.Surface.dialog)
                            }
                        }
                    }
                }
            }
            .onChange(of: highlighted) {
                if visible.indices.contains(highlighted) {
                    proxy.scrollTo(visible[highlighted].id)
                }
            }
        }
    }

    private func row(_ command: PaletteCommand) -> some View {
        let index = visible.firstIndex { $0.id == command.id } ?? 0
        let isHighlighted = index == highlighted
        let requirement = unmetRequirement(command)
        return HStack(spacing: 9) {
            Image(systemName: command.symbol)
                .font(Theme.ui(11))
                .foregroundStyle(isHighlighted ? Theme.Text.onAmber : Theme.Text.disabled)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(isHighlighted ? Theme.Text.onAmber : Theme.Text.primary)
                // Unavailable, not hidden: changing the selection changes
                // what is reachable, and that is only learnable if the
                // greyed rows stay visible.
                if let requirement {
                    Text(requirement)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(
                            isHighlighted ? Theme.Text.onAmber.opacity(0.8) : Theme.Status.orange)
                }
            }
            Spacer(minLength: 0)
            if command.drills {
                Text("›")
                    .font(Theme.ui(12))
                    .foregroundStyle(isHighlighted ? Theme.Text.onAmber : Theme.Text.disabled)
            }
            if let key = command.keyEquivalent {
                Text(key)
                    .font(Theme.mono(10))
                    .foregroundStyle(isHighlighted ? Theme.Text.onAmber : Theme.Text.disabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .opacity(requirement == nil ? 1 : 0.5)
        .background(isHighlighted ? Theme.Accent.amber : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { run(command) }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(legendItems, id: \.self) { item in
                Text(item)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var legendItems: [String] {
        ["↑↓ move", "⏎ run", drilled == nil ? "esc clear" : "esc back", "⌃K close"]
    }

    // MARK: - Matching

    /// Fuzzy enough to be forgiving, strict enough to rank: an exact
    /// prefix beats a word start beats a subsequence.
    private func score(_ title: String, _ query: String) -> Int? {
        let title = title.lowercased(), query = query.lowercased()
        guard !query.isEmpty else { return 0 }
        if title.hasPrefix(query) { return 3 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 2 }
        if title.contains(query) { return 1 }
        // Subsequence: "eoc" finds "Export Copy…".
        var remaining = Substring(query)
        for character in title where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 0 }
        }
        return nil
    }

    private var visible: [PaletteCommand] {
        let commands = drilled?.arguments?() ?? allCommands
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Empty means RECENT — the palette should reward the second
            // use of a command more than the first.
            guard drilled == nil else { return commands }
            let recents = model.paletteRecents
            let byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
            let recent = recents.compactMap { byID[$0] }
            return recent.isEmpty ? commands : recent + commands.filter { !recents.contains($0.id) }
        }
        // Typing a group name narrows to it.
        if let group = PaletteCommand.Group.allCases.first(
            where: { $0.searchWord == trimmed.lowercased() }) {
            return commands.filter { $0.group == group }
        }
        return commands
            .compactMap { command in score(command.title, trimmed).map { ($0, command) } }
            .sorted { $0.0 > $1.0 }
            .map(\.1)
    }

    private func unmetRequirement(_ command: PaletteCommand) -> String? {
        guard command.requiresSelection > 0,
              model.selection.count < command.requiresSelection
        else { return nil }
        return "needs at least \(command.requiresSelection) items selected"
    }

    // MARK: - Running

    private func runHighlighted() {
        guard visible.indices.contains(highlighted) else { return }
        run(visible[highlighted])
    }

    private func run(_ command: PaletteCommand) {
        guard unmetRequirement(command) == nil else { return }
        if command.drills {
            drilled = command
            // Clearing the field is an explicit write: without it the
            // second level inherits the text that opened it.
            query = ""
            highlighted = 0
            return
        }
        model.rememberPaletteCommand(command.id)
        command.run()
        dismiss()
    }

    // MARK: - The inventory
    //
    // Category-derived commands are GENERATED from the library's
    // vocabulary, not hard-coded — a new category gets its filter and
    // tagging commands for free, which is the point of building it this
    // way.

    private var allCommands: [PaletteCommand] {
        goTo + filters + tagging + operations + views
    }

    private func aux(_ kind: AuxWindowRequest.Kind) {
        openWindow(
            id: "aux",
            value: AuxWindowRequest(
                libraryID: model.libraryID, kind: kind,
                // Tag Analysis always walks the current queue.
                itemIDs: kind == .tagAnalysis ? model.visibleItems.map(\.id) : []))
    }

    private var goTo: [PaletteCommand] {
        [
            PaletteCommand(group: .goTo, title: "Categories & Fields", symbol: "tag.square") {
                aux(.categories)
            },
            PaletteCommand(group: .goTo, title: "Import", symbol: "square.and.arrow.down") {
                aux(.importMedia)
            },
            PaletteCommand(group: .goTo, title: "Review", symbol: "checklist") {
                aux(.review)
            },
            PaletteCommand(group: .goTo, title: "Organise", symbol: "folder.badge.gearshape") {
                aux(.organise)
            },
            PaletteCommand(group: .goTo, title: "Maintenance", symbol: "checkmark.seal") {
                aux(.maintenance)
            },
            PaletteCommand(group: .goTo, title: "Tag Analysis", symbol: "tag.square") {
                aux(.tagAnalysis)
            },
            PaletteCommand(group: .goTo, title: "Background Tasks", symbol: "gearshape.2") {
                openWindow(id: "tasks")
            },
            PaletteCommand(group: .goTo, title: "Library Properties", symbol: "info.circle") {
                openWindow(id: "properties", value: model.libraryID)
            },
            PaletteCommand(group: .goTo, title: "Log", symbol: "doc.text") {
                openWindow(id: "log")
            },
        ]
    }

    private var filters: [PaletteCommand] {
        var commands: [PaletteCommand] = [
            PaletteCommand(
                group: .filter, title: "Clear the filter", symbol: "xmark.circle"
            ) { model.clearFilter() },
            PaletteCommand(
                group: .filter, title: "★ Favourites", symbol: "star"
            ) { model.filter.cycle(.status(.favorite)) },
            PaletteCommand(
                group: .filter, title: "Needs review", symbol: "eye.trianglebadge.exclamationmark"
            ) { model.filter.cycle(.status(.needsReview)) },
            PaletteCommand(
                group: .filter, title: "Playback issue", symbol: "play.slash"
            ) { model.filter.cycle(.status(.playbackIssue)) },
            PaletteCommand(
                group: .filter,
                title: model.hideOfflineItems ? "Show offline items" : "Hide offline items",
                symbol: "externaldrive.badge.xmark"
            ) { model.hideOfflineItems.toggle() },
        ]
        for entry in model.vocabulary {
            // The browse filter row's own words, not a paraphrase.
            commands.append(PaletteCommand(
                group: .filter, title: "Missing — no \(entry.category.name) tag",
                symbol: "questionmark.circle"
            ) { model.filter.cycle(.missingCategory(entry.category.id)) })
            commands.append(PaletteCommand(
                group: .filter, title: "\(entry.category.name) is…",
                symbol: "line.3.horizontal.decrease",
                arguments: {
                    entry.tags.map { tag in
                        PaletteCommand(group: .filter, title: tag.name, symbol: "tag") {
                            model.filter.cycle(.tag(tag.id))
                        }
                    }
                }))
        }
        return commands
    }

    private var tagging: [PaletteCommand] {
        var commands: [PaletteCommand] = [
            PaletteCommand(
                group: .tag, title: "Mark reviewed", symbol: "checkmark.circle",
                keyEquivalent: "R", requiresSelection: 1
            ) { model.markSelectionReviewed() },
            PaletteCommand(
                group: .tag, title: "Mark for deletion", symbol: "trash",
                keyEquivalent: "D", requiresSelection: 1
            ) { model.markSelectionForDeletion() },
            PaletteCommand(
                group: .tag, title: "Add to queue", symbol: "play.rectangle",
                requiresSelection: 1
            ) { model.queueSelection() },
        ]
        for entry in model.vocabulary {
            commands.append(PaletteCommand(
                group: .tag, title: "Add a \(entry.category.name) tag…", symbol: "plus.circle",
                requiresSelection: 1,
                arguments: {
                    entry.tags.map { tag in
                        PaletteCommand(group: .tag, title: tag.name, symbol: "tag") {
                            model.applyTagToSelection(tag.id)
                        }
                    }
                }))
        }
        return commands
    }

    /// Operation names come from the one list the grid's context menu and
    /// the Operations window already share.
    private var operations: [PaletteCommand] {
        Operation.allCases.map { operation in
            PaletteCommand(
                group: .do, title: operation.title, symbol: "bolt",
                requiresSelection: operation == .join ? 2 : 1
            ) {
                openWindow(
                    id: "aux",
                    value: AuxWindowRequest(
                        libraryID: model.libraryID, kind: .operations,
                        itemIDs: model.selectedItems.map(\.id)))
            }
        }
    }

    private var views: [PaletteCommand] {
        let display = GridDisplaySettings.shared
        var commands = display.grid.views.map { view in
            PaletteCommand(
                group: .view, title: "Tile view · \(view.name)", symbol: "square.grid.2x2",
                run: {
                    display.grid.activeViewID = view.id
                    display.persist()
                })
        }
        commands.append(PaletteCommand(
            group: .view, title: "Fit tiles to media aspect", symbol: "aspectratio",
            run: {
                display.grid.fitToAspect.toggle()
                display.persist()
            }))
        return commands
    }
}
