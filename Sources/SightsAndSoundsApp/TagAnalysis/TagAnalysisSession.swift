import Foundation
import Observation
import SightsAndSoundsKit

/// The handshake between one player window and its Tag Analysis
/// companion. The player writes what it is showing; the companion
/// writes what it found. Neither learns the other's internals: the
/// player installs `apply` and `step`, the companion calls them.
///
/// Registered in `AppModel` by id so the companion's window request —
/// which must be Codable for saved window state — can carry a UUID
/// rather than an object. A restored window whose id is unknown shows
/// its closed state; it never creates a player.
@Observable @MainActor
final class TagAnalysisSession {
    let id: UUID
    let libraryID: UUID
    let library: LibraryDatabase

    // MARK: Written by the player

    /// What the player is showing. nil until the first load lands.
    private(set) var itemID: UUID?
    /// Where in the playlist — "3 of 41". nil for a single item.
    private(set) var position: (index: Int, count: Int)?
    private(set) var playerIsOpen = true
    /// Apply one tag to the shown item, through the player's own path
    /// so its panel and history refresh. Installed by the player.
    var apply: (Tag) -> Void = { _ in }
    /// The player's next (+1) / previous (−1). Installed by the player.
    var step: (Int) -> Void = { _ in }

    // MARK: Written by the companion

    private(set) var analysis: ItemAnalysis = .empty
    private(set) var isAnalyzing = false
    private(set) var companionIsOpen = false

    init(libraryID: UUID, library: LibraryDatabase) {
        self.id = UUID()
        self.libraryID = libraryID
        self.library = library
    }

    func playerDidShow(itemID: UUID?, position: (index: Int, count: Int)?) {
        self.itemID = itemID
        self.position = position
    }

    func playerDidClose() {
        playerIsOpen = false
        apply = { _ in }
        step = { _ in }
    }

    func companionDidOpen() {
        companionIsOpen = true
    }

    func companionWillReload() {
        isAnalyzing = true
    }

    func companionDidReload(_ analysis: ItemAnalysis) {
        self.analysis = analysis
        isAnalyzing = false
    }

    func companionDidClose() {
        companionIsOpen = false
        isAnalyzing = false
        analysis = .empty
    }

    /// Both sides gone — the registry can drop it.
    var isFinished: Bool { !playerIsOpen && !companionIsOpen }
}
