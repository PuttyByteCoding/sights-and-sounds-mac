import SwiftUI
import SightsAndSoundsKit

/// One library, one window: sidebar (sources, folders, filters) beside the
/// filtered grid. The workspace is a shell composing independent scenes —
/// the 3,930-line lesson from the web app's browse page.
struct LibraryWindowView: View {
    @Environment(AppModel.self) private var app
    let libraryID: UUID
    @State private var model: BrowseModel?
    @State private var openError: String?

    var body: some View {
        Group {
            if let model {
                BrowseView()
                    .environment(model)
                    .navigationTitle(model.libraryName)
            } else if let openError {
                ContentUnavailableView(
                    "Could Not Open Library",
                    systemImage: "exclamationmark.triangle",
                    description: Text(openError))
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            do {
                model = BrowseModel(
                    libraryID: libraryID,
                    library: try app.library(for: libraryID),
                    runner: try app.runner(for: libraryID),
                    onWorkFinished: { [weak app] in app?.signalMaintenance(for: libraryID) })
            } catch {
                openError = "\(error)"
            }
        }
    }
}

struct BrowseView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showViewOptions = false
    @State private var windowWidth: CGFloat = 0

    /// The sidebar's expansion stops where the video's 150 pt floor
    /// begins (#85) — the detail keeps 160 (floor + handle margin); the
    /// player's own dynamic clamps squeeze its right/bottom panels
    /// first, so the video is the last thing standing.
    private var sidebarMax: CGFloat {
        guard windowWidth > 0 else { return 10_000 }
        return max(221, windowWidth - 160)
    }

    /// The former sheets open as WINDOWS (#73) — draggable, resizable,
    /// usable beside the grid.
    private func openAux(_ kind: AuxWindowRequest.Kind) {
        openWindow(id: "aux", value: AuxWindowRequest(libraryID: model.libraryID, kind: kind))
    }

    /// "Video" when one kind is selected, "2 media types" when several —
    /// the toolbar states the scope without repeating the sidebar's list.
    private var kindSummary: String {
        let kinds = model.kinds.ordered
        return kinds.count == 1
            ? kinds[0].displayName
            : "\(kinds.count) media types"
    }

    private var isShuffled: Bool {
        if case .random = model.ordering { return true }
        return false
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 262, max: sidebarMax)
        } detail: {
            // Playback happens in place, in the DETAIL column — the
            // sidebar stays open and usable beside the player. Back (or
            // Esc) returns to the grid exactly as it was left.
            if let request = model.playerRequest {
                PlayerView(request: request) {
                    model.playerRequest = nil
                    model.refreshAll()
                }
                .id(request)  // a new request rebuilds the player from scratch
            } else {
                VStack(spacing: 0) {
                    // The sidebar shows where a filter came from; the chip
                    // bar shows what is currently on.
                    if !model.filter.slottedTerms.isEmpty { FilterChipBar() }
                    if !model.offlineItems.isEmpty { OfflineBanner() }
                    ItemGridView()
                }
                .background(Theme.Surface.content)
                .searchable(
                    text: Binding(
                        get: { model.searchDisplayText },
                        set: { model.setSearchText($0) }),
                    prompt: "Name, path, notes, on-screen text")
            }
        }
        .toolbar {
            // The player contributes its own toolbar while it owns the
            // detail column; hiding the browse set keeps the top bar
            // from doubling up.
            if model.playerRequest == nil {
                ToolbarItem {
                    // The toolbar draws a capsule behind this item sized to
                    // its content; without the padding and fixedSize the
                    // text spills past the capsule at 4+ digit counts (#102).
                    // Media type moved to the sidebar — it is a filter with
                    // several values, not a mode — so the summary of what is
                    // selected comes along beside the count.
                    HStack(spacing: 7) {
                        Text("\(model.visibleItems.count) items")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.Text.quaternary)
                        Text(kindSummary)
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .help("Items visible under the current filter")
                }
                ToolbarItem {
                    Menu {
                        Picker("Order", selection: $model.ordering) {
                            Text("Name").tag(MediaOrdering.fileName)
                            Text("Path").tag(MediaOrdering.relativePath)
                            Text("Full Path (source + path)").tag(MediaOrdering.fullPath)
                            Text("File Size (largest first)").tag(MediaOrdering.fileSize(ascending: false))
                            Text("Duration (longest first)").tag(MediaOrdering.duration(ascending: false))
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button(isShuffled ? "Reshuffle" : "Shuffle") { model.shuffle() }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Order the listing — the play queue follows it")
                }
                ToolbarItem {
                    Button("View Options", systemImage: "slider.horizontal.3") {
                        showViewOptions = true
                    }
                    .help("Thumbnail size, and the fields under each thumbnail")
                    .popover(isPresented: $showViewOptions) {
                        GridViewOptions(onJoinFieldsChange: { model.refreshItems() })
                    }
                }
                ToolbarItem {
                    Button("Import", systemImage: "square.and.arrow.down") {
                        openAux(.importMedia)
                    }
                    .help("Add source folders and scan them for new files")
                }
                ToolbarItem {
                    Button("Categories", systemImage: "tag.square") {
                        openAux(.categories)
                    }
                    .help("Edit this library's categories and tags")
                }
                ToolbarItem {
                    Button {
                        openAux(.duplicates)
                    } label: {
                        Label("Duplicates", systemImage: "rectangle.on.rectangle")
                            .badge(model.pendingDuplicateCount)
                    }
                    .help(model.pendingDuplicateCount > 0
                        ? "\(model.pendingDuplicateCount) duplicate pairs awaiting review"
                        : "No pending duplicate pairs")
                }
                ToolbarItem {
                    Menu {
                        Button("Library Properties…", systemImage: "info.circle") {
                            openWindow(id: "properties", value: model.libraryID)
                        }
                        Divider()
                        Button("Move History…", systemImage: "arrow.turn.up.right") {
                            openAux(.moveHistory)
                        }
                        Button("Reorganize by Template…", systemImage: "folder.badge.gearshape") {
                            openAux(.reorganize)
                        }
                        Button("Validate Library…", systemImage: "checkmark.seal") {
                            openAux(.validation)
                        }
                        Button("Back Up Now", systemImage: "externaldrive.badge.timemachine") {
                            do {
                                let url = try model.library.backup(
                                    into: LibraryDatabase.defaultBackupDirectory())
                                model.errorMessage = nil
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } catch {
                                model.errorMessage = "Backup failed: \(error)"
                            }
                        }
                        Button("Write Tags to Filtered Items", systemImage: "square.and.pencil") {
                            model.writeTags(
                                itemIDs: model.visibleItems.map(\.id),
                                scope: "filtered (\(model.visibleItems.count) files)")
                        }
                        .disabled(model.visibleItems.isEmpty)
                        PurgeButton()
                    } label: {
                        Label("Maintenance", systemImage: "wrench.adjustable")
                    }
                    .help("Move history, reorganize, validate, back up, write tags, purge")
                }
                ToolbarItem {
                    LogWindowButton()
                }
                ToolbarItem {
                    TasksWindowButton()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let status = model.thumbnailQueue {
                ThumbnailQueueBar(status: status)
            }
        }
        .task { await model.watchThumbnailQueue() }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { windowWidth = $0 }
        .frame(minWidth: 900, minHeight: 560)
    }
}

/// The footer under the grid while a thumbnail sweep runs: this
/// library's at-a-glance progress. The Background Tasks window stays
/// the cross-library view.
private struct ThumbnailQueueBar: View {
    let status: BrowseModel.ThumbnailQueueStatus

    var body: some View {
        HStack(spacing: 10) {
            if let total = status.total, total > 0 {
                ProgressView(value: Double(status.current), total: Double(total))
                    .frame(width: 160)
                Text("Generating thumbnails: \(status.current) of \(total)")
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Thumbnail sweep queued…")
            }
            if status.failed > 0 {
                Text("\(status.failed) failed")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Every live filter slot, as a removable chip above the grid.
///
/// The sidebar answers "where did this come from" — a slot sits in the
/// category it belongs to, three sections down, behind a disclosure
/// triangle. This answers "what is on right now", which is the question
/// you have when the grid shows fewer items than you expected.
private struct FilterChipBar: View {
    @Environment(BrowseModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            FlowRow(spacing: 7) {
                ForEach(model.filter.slottedTerms, id: \.term) { entry in
                    chip(term: entry.term, slot: entry.slot)
                }
            }
            Spacer(minLength: 0)
            Button("Clear all") { model.filter.clearSlots() }
                .buttonStyle(.plain)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.Surface.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    @ViewBuilder
    private func chip(term: FilterTerm, slot: MediaFilter.TagSlot) -> some View {
        if let label = model.chipLabel(for: term) {
            HStack(spacing: 6) {
                Circle()
                    .fill(slot.color)
                    .frame(width: 6, height: 6)
                Text("\(label.group) · \(label.value)")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(slot.color)
                    .strikethrough(slot == .excluded)
                Button {
                    model.filter.setSlot(nil, for: term)
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.ui(9, .semibold))
                        .foregroundStyle(slot.color.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(slot.color.opacity(0.12))
                    .stroke(slot.color.opacity(0.4), lineWidth: 1))
            .help("\(slot.name) — \(slot.legend)")
        }
    }
}

/// What an offline source actually costs you, stated plainly.
///
/// Cached thumbnails mean an offline source's tiles look completely
/// normal — only playback and file operations fail. So the banner says
/// exactly that rather than implying the items are gone, and its action
/// is a real toggle: hiding them is a choice, and the count of what was
/// hidden is kept against the listing before the toggle so the state is
/// recoverable.
private struct OfflineBanner: View {
    @Environment(BrowseModel.self) private var model

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(Theme.Status.orange)
                .frame(width: 8, height: 8)
            Text(message)
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.Status.warnText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(model.hideOfflineItems ? "Show offline items" : "Hide offline items") {
                model.hideOfflineItems.toggle()
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.Status.warnBadgeFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.activeCard).frame(height: 1)
        }
    }

    private var message: String {
        let offline = model.offlineItems.count
        let sources = model.offlineSourceNames.formatted(
            .list(type: .and, width: .standard))
        if model.hideOfflineItems {
            return """
                \(offline) items on \(sources) are hidden. Their tags, fields and \
                thumbnails are local and still current.
                """
        }
        return """
            \(offline) of these \(model.items.count) items live on \(sources) — tags, \
            fields and thumbnails are local and current. Only playback and file \
            operations are unavailable.
            """
    }
}
