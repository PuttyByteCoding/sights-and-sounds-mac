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

        var title: String {
            switch self {
            case .categories: "Categories & Fields"
            case .review: "Review"
            case .organise: "Organise"
            case .maintenance: "Maintenance"
            case .importMedia: "Import"
            case .operations: "Operations"
            case .watched: "Recently Watched"
            case .tagAnalysis: "Tag Analysis"
            case .player: "Player"
            }
        }
    }

    var libraryID: UUID
    var kind: Kind
    /// The selection an operation acts on. Empty for every other
    /// surface — the operations window is the only one that opens
    /// against a set of items.
    var itemIDs: [UUID] = []
    /// Tag Analysis only: where in `itemIDs` to start the walk.
    /// Optional so window state saved before this field decodes.
    var startIndex: Int? = nil
    /// A display title beating the kind's own — "Tag: Mike Jones" on a
    /// player window. Optional so saved window state decodes.
    var title: String? = nil
}

/// Hosts one auxiliary surface in its own window, with its own
/// BrowseModel over the shared library handle. Cross-window edits
/// reconcile through the library-data-changed broadcast — whichever
/// model writes, every window over that library follows.
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
        .task {
            guard model == nil else { return }
            do {
                let made = BrowseModel(
                    libraryID: request.libraryID,
                    library: try app.library(for: request.libraryID),
                    runner: try app.runner(for: request.libraryID),
                    onWorkFinished: { [weak app] in
                        app?.signalMaintenance(for: request.libraryID)
                    })
                // A player window plays on arrival: the request carries
                // its whole queue, so there is nothing to browse first.
                if request.kind == .player, let first = request.itemIDs.first {
                    made.playerRequest = PlayerRequest(
                        libraryID: request.libraryID, itemID: first,
                        playlist: request.itemIDs)
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
                    model.refreshAll()
                }
            }
            .id(playing)
        } else {
            switch request.kind {
            case .categories: CategoryManagerView()
            case .review: ReviewView()
            case .organise: OrganiseView()
            case .maintenance: MaintenanceView()
            case .importMedia: ImportView()
            case .operations: OperationsView(itemIDs: request.itemIDs)
            case .watched: WatchedView()
            case .tagAnalysis:
                TagAnalysisView(
                    queueIDs: request.itemIDs, startIndex: request.startIndex ?? 0)
            case .player:
                // Only reachable when the request carried no items.
                ContentUnavailableView(
                    "Nothing to Play", systemImage: "play.slash",
                    description: Text("No items carry this tag yet."))
            }
        }
    }
}
