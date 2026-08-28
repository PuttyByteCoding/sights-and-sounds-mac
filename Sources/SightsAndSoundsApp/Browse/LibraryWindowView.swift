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

    private var isShuffled: Bool {
        if case .random = model.ordering { return true }
        return false
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: sidebarMax)
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
                ItemGridView()
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
                ToolbarItem(placement: .principal) {
                    Picker("Kind", selection: $model.kind) {
                        Text("Video").tag(MediaKind.video)
                        Text("Audio").tag(MediaKind.audio)
                    }
                    .pickerStyle(.segmented)
                    .help("Every listing is one media kind at a time — video or audio")
                }
                ToolbarItem {
                    // The toolbar draws a capsule behind this item sized to
                    // its content; without the padding and fixedSize the
                    // text spills past the capsule at 4+ digit counts (#102).
                    Text("\(model.items.count) items")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
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
                                itemIDs: model.items.map(\.id),
                                scope: "filtered (\(model.items.count) files)")
                        }
                        .disabled(model.items.isEmpty)
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
