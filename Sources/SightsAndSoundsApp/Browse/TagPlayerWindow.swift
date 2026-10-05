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
    tag: Tag, service: any LibraryService, libraryID: UUID, openWindow: OpenWindowAction
) {
    Task {
        // The library's own answer to "the items with this tag", which
        // is also what Refresh in that window asks again.
        let ids = ((try? await service.queueItems(.tag(id: tag.id, name: tag.name))) ?? []).map(\.id)
        openWindow(
            id: "aux",
            value: AuxWindowRequest(
                libraryID: libraryID, kind: .player, itemIDs: ids,
                title: "Tag: \(tag.name)", tagID: tag.id))
    }
}
