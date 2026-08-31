import SwiftUI
import SightsAndSoundsKit

/// Open a standalone player window whose queue is every item wearing one
/// tag — "is this really the taper I think it is?" answered by WATCHING
/// the company the tag keeps, with the full transport, not by squinting
/// at thumbnails.
///
/// One window per tag (the aux window group keys on the request), each
/// with its own model and queue — so comparing two tapers is two windows
/// side by side. Newest-ingested first, so a fresh mistake is the first
/// thing that plays.
@MainActor
func openTagPlayerWindow(
    tag: Tag, library: LibraryDatabase, libraryID: UUID, openWindow: OpenWindowAction
) {
    let ids = ((try? library.items(withTag: tag.id, limit: 10_000))?.items ?? []).map(\.id)
    openWindow(
        id: "aux",
        value: AuxWindowRequest(
            libraryID: libraryID, kind: .player, itemIDs: ids,
            title: "Tag: \(tag.name)"))
}
