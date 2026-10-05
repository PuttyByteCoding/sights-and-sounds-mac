import SwiftUI
import SightsAndSoundsKit

/// Identifies one auxiliary workspace window: a library plus which
/// surface it shows. These were modal sheets — as windows they're
/// draggable, resizable, and usable BESIDE the grid (reviewing
/// duplicates while browsing is the concrete win).
struct AuxWindowRequest: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case categories
        case review
        case organise
        case maintenance
        case importMedia
        case operations
        case watched
        case tagAnalysis
        /// A standalone player over a queue the request carries — "the
        /// videos wearing this tag", or any other set. One window per
        /// distinct request, each with its own model and queue, which is
        /// what makes several players-at-once just work.
        case player
        /// Firefox bookmarks matching one item's search values (spec 17).
        case bookmarkSearch

        /// Whether the surface asks everything of the library's service,
        /// and so works on a library another Mac holds. The others still
        /// work on a database; the list grows as they are moved.
        var worksOnARemoteLibrary: Bool {
            switch self {
            case .player, .categories, .watched, .bookmarkSearch, .review: true
            case .organise, .maintenance, .importMedia, .operations, .tagAnalysis: false
            }
        }

        var title: String {
            switch self {
            case .categories: "Tag Manager"
            case .review: "Review"
            case .organise: "Organise"
            case .maintenance: "Maintenance"
            case .importMedia: "Import"
            case .operations: "Operations"
            case .watched: "History"
            case .tagAnalysis: "Tag Analysis"
            case .player: "Player"
            case .bookmarkSearch: "Bookmarks"
            }
        }
    }

    var libraryID: UUID
    var kind: Kind
    /// The selection an operation acts on. Empty for every other
    /// surface — the operations window is the only one that opens
    /// against a set of items.
    var itemIDs: [UUID] = []
    /// Unused since Tag Analysis followed a player session; kept so
    /// saved window state decodes.
    var startIndex: Int? = nil
    /// A display title beating the kind's own — "Tag: Mike Jones" on a
    /// player window. Optional so saved window state decodes.
    var title: String? = nil
    /// Tag Analysis only: the player session the companion follows.
    /// Optional so saved window state decodes; a missing or unknown id
    /// renders the companion's closed state.
    var sessionID: UUID? = nil
    /// Player kind: the tag whose items the queue holds, so Refresh can
    /// re-run it. Optional so saved window state decodes.
    var tagID: UUID? = nil
    /// Organise and Maintenance: the items the grid showed when the
    /// window was opened — what "the filtered items" means there. The
    /// window's own model starts unfiltered, so without this they acted
    /// on the whole library. Nil (a window saved before this existed)
    /// is the whole library, and says so.
    var scopeItemIDs: [UUID]? = nil
    /// Import: the source to scan as the window opens — "Import New
    /// Files" on a source, or Maintenance's "Import Now" on an orphan.
    /// Optional so saved window state decodes.
    var sourceID: UUID? = nil
}

/// Hosts one auxiliary surface in its own window, with its own
/// BrowseModel over the shared library handle. Cross-window edits
/// reconcile through the library's change hub — whoever writes, every
/// window over that library follows.
struct AuxiliaryWindowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: AuxWindowRequest
    @State private var model: BrowseModel?
    @State private var openError: String?

    var body: some View {
        Group {
            if let model {
                content(model)
                    .environment(model)
                    .focusedSceneValue(\.searchSubject, model.searchSubject)
                    .navigationTitle(
                        "\(model.libraryName) — \(request.title ?? request.kind.title)")
            } else if let openError {
                ContentUnavailableView(
                    "Could Not Open Library",
                    systemImage: "exclamationmark.triangle",
                    description: Text(openError))
            } else {
                ProgressView()
            }
        }
        .defaultToolbarShowsLabels()
        .environment(\.libraryIsRemote, model?.isRemote ?? false)
        .task { [app] in
            guard model == nil else { return }
            do {
                let made: BrowseModel
                if let remote = app.remoteLibraries.ref(for: request.libraryID),
                   let service = app.remoteLibraries.service(for: request.libraryID) {
                    made = try BrowseModel(
                        libraryID: request.libraryID, name: remote.library.name, hostName: remote.host.name,
                        service: service,
                        connection: RemoteConnectionNote.notes(of: service, hostName: remote.host.name))
                } else {
                    made = BrowseModel(
                        libraryID: request.libraryID,
                        library: try app.library(for: request.libraryID),
                        runner: try app.runner(for: request.libraryID),
                        onWorkFinished: { [weak app] in
                            app?.signalMaintenance(for: request.libraryID)
                        })
                }
                // A player window plays on arrival: the request carries
                // its whole queue, so there is nothing to browse first.
                if request.kind == .player, let first = request.itemIDs.first {
                    let definition: QueueDefinition = request.tagID.map {
                        .tag(id: $0, name: request.title?.replacingOccurrences(of: "Tag: ", with: "") ?? "Tag")
                    } ?? .explicit(ids: request.itemIDs, name: request.title ?? "Queue")
                    made.playerRequest = PlayerRequest(
                        libraryID: request.libraryID, itemID: first,
                        definition: definition, playlist: request.itemIDs)
                }
                model = made
            } catch {
                openError = "\(error)"
            }
        }
    }

    @ViewBuilder
    private func content(_ model: BrowseModel) -> some View {
        // Play from an auxiliary window (Duplicates' compare pane) plays
        // right here — same in-place pattern as the library window.
        if let playing = model.playerRequest {
            PlayerView(request: playing) {
                // A player-kind window IS its player — Back closes the
                // window rather than stranding an empty shell.
                if request.kind == .player {
                    dismiss()
                } else {
                    model.playerRequest = nil
                }
            }
            .id(playing)
        } else {
            switch request.kind {
            case .categories: CategoryManagerView()
            case .review: ReviewView()
            case .organise: OrganiseView(scope: request.scopeItemIDs)
            case .maintenance: MaintenanceView(scope: request.scopeItemIDs)
            case .importMedia: ImportView(initialSourceID: request.sourceID)
            case .operations: OperationsView(itemIDs: request.itemIDs)
            case .watched: WatchedView()
            case .tagAnalysis:
                TagAnalysisView(sessionID: request.sessionID)
            case .bookmarkSearch:
                BookmarkSearchView(itemID: request.itemIDs.first)
            case .player:
                // Only reachable when the request carried no items.
                ContentUnavailableView(
                    "Nothing to Play", systemImage: "play.slash",
                    description: Text("No items carry this tag yet."))
            }
        }
    }
}
