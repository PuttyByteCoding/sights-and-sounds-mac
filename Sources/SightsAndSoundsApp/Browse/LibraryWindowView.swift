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
                model = BrowseModel(libraryID: libraryID, library: try app.library(for: libraryID))
            } catch {
                openError = "\(error)"
            }
        }
    }
}

struct BrowseView: View {
    @Environment(BrowseModel.self) private var model

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
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
