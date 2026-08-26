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
    @State private var showCategoryManager = false
    @State private var showDuplicates = false
    @State private var showMoveHistory = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            ItemGridView()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Kind", selection: $model.kind) {
                    Text("Video").tag(MediaKind.video)
                    Text("Audio").tag(MediaKind.audio)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Text("\(model.items.count) items")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ToolbarItem {
                Button("Categories", systemImage: "tag.square") {
                    showCategoryManager = true
                }
                .help("Edit this library's categories and tags")
            }
            ToolbarItem {
                Button {
                    showDuplicates = true
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
                    Button("Move History…", systemImage: "arrow.turn.up.right") {
                        showMoveHistory = true
                    }
                    PurgeButton()
                } label: {
                    Label("Maintenance", systemImage: "wrench.adjustable")
                }
            }
            ToolbarItem {
                TasksWindowButton()
                    .help("Imports, hashing, thumbnails — across all libraries")
            }
        }
        .sheet(isPresented: $showCategoryManager) {
            CategoryManagerView()
                .environment(model)
        }
        .sheet(isPresented: $showDuplicates) {
            DuplicatesView()
                .environment(model)
        }
        .sheet(isPresented: $showMoveHistory) {
            MoveHistoryView()
                .environment(model)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
