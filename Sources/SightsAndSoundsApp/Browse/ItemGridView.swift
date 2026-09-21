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
    /// The grid's width, for working out how many columns an up or down
    /// arrow should cross.
    @State private var gridWidth: CGFloat = 0

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
            if let error = model.listingError {
                EmptyGridState(
                    title: "Query Failed", detail: error, symbol: "exclamationmark.triangle")
            } else if model.visibleItems.isEmpty {
                emptyState
            } else {
                ScrollViewReader { scroller in listing(scroller) }
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
            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.errorMessage = nil }
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
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

    /// The grid itself, out of `body`: the older CI compiler gives up
    /// type-checking a body this deep.
    private func listing(_ scroller: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(model.visibleItems) { item in
                    ItemCell(item: item, hasKeyboardFocus: focused && model.focusedItemID == item.id)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        // The focus can be moved off screen by the keyboard;
        // follow it, by as little as it takes.
        .onChange(of: model.focusedItemID) { _, id in
            guard let id else { return }
            scroller.scrollTo(id)
        }
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

    private static let focusMoves: [KeyEquivalent: GridFocusMove] = [
        .leftArrow: .left, .rightArrow: .right, .upArrow: .up, .downArrow: .down,
    ]

    /// Arrows move the focus, Return plays it, Space selects it.
    /// `V` cycles the saved views; Esc unwinds exactly one layer — the
    /// selection here, since a popover takes the key press itself.
    private func handle(_ press: KeyPress) -> Bool {
        if press.key == .escape, !model.selection.isEmpty {
            model.clearSelection()
            return true
        }
        if let move = Self.focusMoves[press.key], press.modifiers.isEmpty {
            model.moveFocus(move, columns: GridFocus.columns(
                width: gridWidth, tileMinimum: GridDisplaySettings.shared.grid.thumbnailSize))
            return true
        }
        if press.key == .return, model.focusedItemID != nil {
            model.playFocusedItem()
            return true
        }
        if press.key == .space, model.focusedItemID != nil {
            model.toggleSelectionOfFocusedItem()
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

/// Something the user asked for did not happen. Over the grid, not
/// instead of it, and it stays until it is dismissed.
private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Status.red)
            Text(message)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(Theme.ui(9, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Text.tertiary)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button)
                .fill(Theme.Surface.iconTile)
                .stroke(Theme.Status.red.opacity(0.5), lineWidth: 1))
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
    let item: MediaItem
    /// The keyboard is on this tile (and the grid has the keyboard).
    var hasKeyboardFocus = false
    @State private var thumbnail: NSImage?
    /// The tag action a right-click on one of this tile's pills picked.
    @State private var pending: TagAction?

    var body: some View {
        TileCard(
            item: item,
            context: model.tileContext(for: item),
            view: GridDisplaySettings.shared.grid.activeView,
            grid: GridDisplaySettings.shared.grid,
            thumbnail: thumbnail,
            isSelected: model.selection.contains(item.id),
            // A tag pill on a tile IS a tag: right-clicking one gets the
            // tag's menu, while right-clicking the tile around it still
            // gets the item's own.
            tagMenu: { id in
                guard let tag = model.vocabulary.flatMap(\.tags).first(where: { $0.id == id })
                else { return AnyView(EmptyView()) }
                return AnyView(TagActionButtons(
                    tag: tag, library: model.library, libraryID: model.libraryID,
                    pending: $pending,
                    removal: TagRemoval(label: TagRemoval.label(for: item.kind)) {
                        model.attempt("remove the tag") {
                            try model.library.removeTag(tag.id, from: item.id)
                        }
                    },
                    itemID: item.id))
            })
            // Where the keyboard is. An outline rather than a fill, so it
            // reads as "here" and not as "selected", which is the amber
            // border the tile draws itself.
            .overlay {
                if hasKeyboardFocus {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .stroke(Theme.Text.primary.opacity(0.7), lineWidth: 2)
                        .padding(-3)
                }
            }
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
            // Two tap gestures give a tile no role and no way to be
            // pressed. It is a button that plays, that can also be
            // selected.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.fileName)
            .accessibilityAddTraits(
                model.selection.contains(item.id) ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default) { play() }
            .accessibilityAction(named: "Select") {
                model.click(item.id, extend: true, range: false)
            }
            .tagActions(
                $pending, library: model.library, libraryID: model.libraryID,
                categories: model.vocabulary.map(\.category),
                onChange: {})
            // Keyed on the size as well: a tile enlarged with the slider
            // is decoded again at its new size rather than stretched.
            .task(id: "\(item.id)@\(ThumbnailImages.bucket(GridDisplaySettings.shared.grid.thumbnailSize))") {
                let data = await ThumbnailProvider.shared.thumbnailData(
                    itemID: item.id,
                    libraryID: model.libraryID,
                    durationSeconds: item.durationSeconds,
                    resolveFile: model.fileResolver(for: item))
                // An adaptive column is at most 1.4× the chosen size.
                thumbnail = await ThumbnailImages.shared.image(
                    libraryID: model.libraryID, itemID: item.id, data: data,
                    points: GridDisplaySettings.shared.grid.thumbnailSize * 1.4)
            }
    }

    @ViewBuilder private var menu: some View {
        Button("Play", systemImage: "play") { play() }
            .disabled(!model.isOnline(item))
        Button(
            item.isFavorite ? "Remove from Favourites" : "Add to Favourites",
            systemImage: item.isFavorite ? "star.slash" : "star"
        ) {
            model.attempt("change the favourite") {
                _ = try model.library.toggleFlag(.favorite, itemID: item.id)
            }
        }
        Divider()
        // File-location actions, not media operations.
        Button("Show in Finder", systemImage: "folder") { revealInFinder() }
            .disabled(!model.isOnline(item))
        Button("Open Terminal at Folder", systemImage: "terminal") { openTerminal() }
            .disabled(!model.isOnline(item))
        Divider()
        // The name as it is on disk, and a search-box-friendly form with
        // the punctuation turned into spaces. Neither needs the file online.
        Button("Copy File Name", systemImage: "doc.on.doc") {
            Clipboard.copy(item.fileName)
        }
        Button("Copy File Name (Letters and Numbers)", systemImage: "doc.on.doc") {
            Clipboard.copy(item.fileName.lettersAndNumbersOnly)
        }
        Button("Tag Analysis", systemImage: "sparkle.magnifyingglass") {
            // The companion follows a player, so the player opens first
            // at this video, over the whole listing, and opens it.
            model.openPlayerForAnalysis(at: item.id)
        }
        if item.parentMediaItemID != nil && !item.isExportedClip {
            Button("Export Clip to File", systemImage: "scissors") {
                model.exportClip(item)
            }
            .disabled(!model.isOnline(item))
        }
        if item.markedForDeletion {
            Button("Restore from Deletion Staging", systemImage: "arrow.uturn.backward") {
                model.attempt("restore \(item.fileName)") {
                    try model.library.unstage(.toDelete, itemID: item.id)
                }
            }
        }
        if item.playbackIssue {
            Button("Clear Playback Issue", systemImage: "play.circle") {
                model.attempt("clear the playback issue") {
                    try model.library.unstage(.playbackIssue, itemID: item.id)
                }
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

    private func play() { model.play(item) }

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
