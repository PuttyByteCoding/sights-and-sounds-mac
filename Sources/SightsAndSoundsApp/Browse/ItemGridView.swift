import SwiftUI
import SightsAndSoundsKit

/// The grid: one tile per item, drawn by the active view, with the bulk
/// bar floating over it while a selection exists.
struct ItemGridView: View {
    @Environment(BrowseModel.self) private var model
    @FocusState private var focused: Bool
    /// The view name, shown for a moment after `V` cycles — otherwise
    /// the whole grid changes and nothing says why.
    @State private var viewToast: String?

    // Cell size is a view option; the adaptive maximum tracks the
    // chosen minimum so cells stay near the picked size. Tiles top-align
    // so a ragged row keeps a tidy edge.
    private var columns: [GridItem] {
        // Observable read — the View Options slider resizes cells LIVE.
        let size = GridDisplaySettings.shared.grid.thumbnailSize
        return [GridItem(.adaptive(minimum: size, maximum: size * 1.4), spacing: 16, alignment: .top)]
    }

    var body: some View {
        Group {
            if let error = model.errorMessage {
                EmptyGridState(
                    title: "Query Failed", detail: error, symbol: "exclamationmark.triangle")
            } else if model.visibleItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(model.visibleItems) { item in
                            ItemCell(item: item)
                                .transition(.opacity)
                        }
                    }
                    .padding(16)
                    // The listing is DIFFED, not blanked: tiles that survive
                    // the filter change slide to their new positions while
                    // departures fade out and arrivals fade in. Keyed on the
                    // ids, so a re-query returning the same items animates
                    // nothing — and a rapid cycle interrupts cleanly instead
                    // of stacking fades.
                    .animation(
                        .easeInOut(duration: Theme.Motion.listingSettle),
                        value: model.visibleItems.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Surface.content)
        // The same pattern the player uses: focus lives on the grid, so
        // a bare key press cannot fire while the search field has it.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress { press in handle(press) ? .handled : .ignored }
        .onAppear { focused = true }
        .overlay(alignment: .top) {
            if let viewToast {
                Text(viewToast)
                    .font(Theme.ui(11.5, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.button)
                            .fill(Theme.Surface.iconTile)
                            .stroke(Theme.Border.raised, lineWidth: 1))
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if !model.selection.isEmpty { BulkBar() }
        }
        .animation(.easeOut(duration: 0.15), value: viewToast)
    }

    @ViewBuilder private var emptyState: some View {
        if model.filter.isEmpty && !model.hideOfflineItems {
            EmptyGridState(
                title: "No Items",
                detail: "Add a source and import media to fill this library.",
                symbol: "film.stack")
        } else {
            EmptyGridState(
                title: "Nothing matches this filter",
                detail: "Loosen a required slot, or clear the filter.",
                symbol: "line.3.horizontal.decrease.circle")
        }
    }

    /// `V` cycles the saved views; Esc unwinds exactly one layer — the
    /// selection here, since a popover takes the key press itself.
    private func handle(_ press: KeyPress) -> Bool {
        if press.key == .escape, !model.selection.isEmpty {
            model.clearSelection()
            return true
        }
        guard press.characters.lowercased() == "v", press.modifiers.isEmpty else { return false }
        let display = GridDisplaySettings.shared
        let views = display.grid.views
        guard views.count > 1 else { return false }
        let next = views[(display.grid.activeIndex + 1) % views.count]
        display.grid.activeViewID = next.id
        display.persist()
        viewToast = "View · \(next.name)"
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            if viewToast == "View · \(next.name)" { viewToast = nil }
        }
        return true
    }
}

private struct EmptyGridState: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(Theme.Text.disabled)
                .padding(.bottom, 4)
            Text(title)
                .font(Theme.ui(15, .semibold))
                .foregroundStyle(Theme.Text.quaternary)
            Text(detail)
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.Text.disabled)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ItemCell: View {
    @Environment(BrowseModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let item: MediaItem
    @State private var thumbnail: NSImage?
    /// The tag whose editor is open, from a right-click on one of this
    /// tile's pills.
    @State private var editingTag: Tag?

    var body: some View {
        TileCard(
            item: item,
            context: model.tileContext(for: item),
            view: GridDisplaySettings.shared.grid.activeView,
            grid: GridDisplaySettings.shared.grid,
            thumbnail: thumbnail,
            isSelected: model.selection.contains(item.id),
            // A tag pill on a tile IS a tag: right-clicking one edits it,
            // while right-clicking the tile around it still gets the
            // item's own menu.
            onEditTag: { id in
                editingTag = model.vocabulary
                    .flatMap(\.tags)
                    .first { $0.id == id }
            })
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { play() }
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                model.click(
                    item.id,
                    extend: flags.contains(.command),
                    range: flags.contains(.shift))
            }
            .contextMenu { menu }
            .sheet(item: $editingTag) { tag in
                TagSheet(
                    mode: .edit(tag),
                    library: model.library,
                    libraryID: model.libraryID,
                    categories: model.vocabulary.map(\.category),
                    onSaved: { _ in model.refreshAll() })
            }
            .task(id: item.id) {
                let data = await ThumbnailProvider.shared.thumbnailData(
                    itemID: item.id,
                    libraryID: model.libraryID,
                    fileURL: model.fileURL(for: item),
                    durationSeconds: item.durationSeconds)
                thumbnail = data.flatMap(NSImage.init(data:))
            }
    }

    @ViewBuilder private var menu: some View {
        Button("Play", systemImage: "play") { play() }
            .disabled(!model.isOnline(item))
        Divider()
        // File-location actions, not media operations.
        Button("Show in Finder", systemImage: "folder") { revealInFinder() }
            .disabled(!model.isOnline(item))
        Button("Open Terminal at Folder", systemImage: "terminal") { openTerminal() }
            .disabled(!model.isOnline(item))
        Button("Tag Analysis on This Item", systemImage: "sparkle.magnifyingglass") {
            openWindow(
                id: "aux",
                value: AuxWindowRequest(
                    libraryID: model.libraryID, kind: .tagAnalysis, itemIDs: [item.id]))
        }
        if item.parentMediaItemID != nil && !item.isExportedClip {
            Button("Export Clip to File", systemImage: "scissors") {
                model.exportClip(item)
            }
            .disabled(!model.isOnline(item))
        }
        if item.markedForDeletion {
            Button("Restore from Deletion Staging", systemImage: "arrow.uturn.backward") {
                try? model.library.unstage(.toDelete, itemID: item.id)
                model.refreshAll()
            }
        }
        if item.playbackIssue {
            Button("Clear Playback Issue", systemImage: "play.circle") {
                try? model.library.unstage(.playbackIssue, itemID: item.id)
                model.refreshAll()
            }
        }
        if item.parentMediaItemID == nil {
            Divider()
            Button("Optimize (Faststart)", systemImage: "bolt") {
                model.remux(item, mode: .optimize)
            }
            .disabled(!model.isOnline(item))
            Button("Repair Container", systemImage: "bandage") {
                model.remux(item, mode: .repair)
            }
            .disabled(!model.isOnline(item))
            Menu("Encode a Copy") {
                ForEach(EncodeJob.Preset.allCases, id: \.self) { preset in
                    Button(preset.displayName) { model.encode(item, preset: preset) }
                }
            }
            .disabled(!model.isOnline(item))
            Button("Write Tags to File", systemImage: "square.and.pencil") {
                model.writeTags(itemIDs: [item.id], scope: item.fileName)
            }
            .disabled(!model.isOnline(item))
            let snapshots = model.snapshots(of: item.id)
            if !snapshots.isEmpty {
                Menu("Restore Embedded Tags") {
                    ForEach(snapshots) { snapshot in
                        Button("\(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened)) (\(snapshot.source.rawValue))") {
                            model.restoreSnapshot(snapshot.id)
                        }
                    }
                }
                .disabled(!model.isOnline(item))
            }
            Button("Scan On-Screen Text (OCR)", systemImage: "text.viewfinder") {
                model.scanText(item)
            }
            .disabled(!model.isOnline(item) || item.kind != .video)
            Button("Join Folder's Files", systemImage: "link") {
                model.joinFolder(of: item)
            }
            .disabled(!model.isOnline(item))
            if model.hasHideBlocks(item) {
                Button("Export Copy Without Hidden Blocks", systemImage: "eye.slash") {
                    model.removeBlocks(item)
                }
                .disabled(!model.isOnline(item))
            }
        }
    }

    private func play() {
        guard model.isOnline(item) else { return }
        model.playerRequest = PlayerRequest(
            libraryID: model.libraryID, itemID: item.id,
            playlist: model.visibleItems.map(\.id))
    }

    // An embedded clip resolves to its parent's file — the file on disk.
    private func revealInFinder() {
        guard let url = model.fileURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openTerminal() {
        guard let url = model.fileURL(for: item) else { return }
        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal")
        else {
            model.errorMessage = "Terminal.app could not be found."
            return
        }
        // Opening a DIRECTORY with Terminal starts a shell there.
        let model = model
        NSWorkspace.shared.open(
            [url.deletingLastPathComponent()], withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                Task { @MainActor in
                    model.errorMessage = "Open Terminal failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// The bulk bar floats OVER the grid, bottom centre, rather than docking
/// to an edge — the sidebar stays reachable, which matters because the
/// thing you usually do next is change the filter.
private struct BulkBar: View {
    @Environment(BrowseModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showTagPicker = false

    var body: some View {
        HStack(spacing: 9) {
            Text("\(model.selection.count) selected")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.Accent.amber)
            divider
            Button("Add tags") { showTagPicker = true }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .popover(isPresented: $showTagPicker, arrowEdge: .top) {
                    BulkTagPicker()
                }
            Button("Mark reviewed") { model.markSelectionReviewed() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            Button("Add to queue") { model.queueSelection() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            Button("Mark for deletion") { model.markSelectionForDeletion() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            // The context menu still handles one item; a SELECTION goes
            // to the window that says what an operation will cost.
            Button("Operations…") {
                openWindow(
                    id: "aux",
                    value: AuxWindowRequest(
                        libraryID: model.libraryID, kind: .operations,
                        itemIDs: model.selectedItems.map(\.id)))
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            divider
            Button("Deselect · esc") { model.clearSelection() }
                .buttonStyle(.plain)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Surface.iconTile)
                .stroke(Theme.Border.subtleButtonHover, lineWidth: 1)
                .shadow(color: .black.opacity(0.65), radius: 24, y: 12))
        .padding(.bottom, 18)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Border.raised)
            .frame(width: 1, height: 17)
    }
}

/// Tagging a selection: the vocabulary, narrowed by typing, one click per
/// tag. It goes through `assignTag` per item, so a single-select category
/// still replaces rather than accumulates.
private struct BulkTagPicker: View {
    @Environment(BrowseModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add tags to \(model.selection.count) items")
                .modifier(Theme.sectionLabel())
            TextField("Find a tag", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.vocabulary) { entry in
                        let tags = matches(in: entry)
                        if !tags.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.category.name)
                                    .modifier(Theme.sectionLabel(
                                        Theme.categoryHue(entry.category.colorIndex)))
                                FlowRow(spacing: 5) {
                                    ForEach(tags) { tag in
                                        Button {
                                            model.applyTagToSelection(tag.id)
                                        } label: {
                                            Text(tag.name)
                                                .font(Theme.ui(11.5))
                                                .foregroundStyle(Theme.Text.secondary)
                                                .padding(.vertical, 3)
                                                .padding(.horizontal, 9)
                                                .background {
                                                    Capsule()
                                                        .fill(Theme.categoryHue(
                                                            entry.category.colorIndex)
                                                            .opacity(0.12))
                                                        .stroke(
                                                            Theme.categoryHue(
                                                                entry.category.colorIndex)
                                                                .opacity(0.35), lineWidth: 1)
                                                }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, height: 340)
        .background(Theme.Surface.dialog)
    }

    private func matches(in entry: CategoryTags) -> [Tag] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entry.tags }
        return entry.tags.filter { tag in
            tag.name.localizedCaseInsensitiveContains(query)
                || (model.tagAliases[tag.id] ?? [])
                    .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}
