import Foundation
import GRDB
@testable import SightsAndSoundsKit

/// A small library exercising every filter term type. Synthetic throughout —
/// real library data never enters this repo or CI.
struct FilterFixture {
    let library: LibraryDatabase

    // Categories
    let band = TagCategory(name: "Band")
    let recordingType = TagCategory(name: "Recording Type", sortOrder: 1)

    // Tags
    let bandA: Tag
    let bandB: Tag
    let sbd: Tag
    let aud: Tag
    /// Hidden-by-default: items carrying it vanish unless it is referenced.
    let secret: Tag

    // Items, named by scenario.
    let show1995 = MediaItem(kind: .video, relativePath: "shows/1995/a.mp4", needsReview: false)
    let show1995Disc2 = MediaItem(kind: .video, relativePath: "shows/1995/disc2/b.mp4", needsReview: false)
    let show2001 = MediaItem(kind: .video, relativePath: "shows/2001/c.mp4", needsReview: false)
    let hiddenShow = MediaItem(kind: .video, relativePath: "shows/2001/d.mp4", needsReview: false)
    let audioOnly = MediaItem(kind: .audio, relativePath: "misc/e.flac", needsReview: false)
    let underscoreDir = MediaItem(kind: .video, relativePath: "shows/my_band/f.mp4", needsReview: false)
    let underscoreDecoy = MediaItem(kind: .video, relativePath: "shows/myxband/g.mp4", needsReview: false)
    let flagged = MediaItem(
        kind: .video, relativePath: "flags/h.mp4",
        needsReview: true, isFavorite: true)
    let embeddedClip: MediaItem
    let markedClip = MediaItem(
        kind: .video, relativePath: "clips/j.mp4",
        needsReview: false, isClip: true, isEdited: true)
    let exportedClip = MediaItem(
        kind: .video, relativePath: "clips/k.mp4",
        needsReview: false, isExportedClip: true)
    /// An embedded clip row whose range was exported — hidden from every surface.
    let spentClipRow: MediaItem

    init() throws {
        library = try LibraryDatabase.openInMemory()

        bandA = Tag(tagCategoryID: band.id, name: "Band A")
        bandB = Tag(tagCategoryID: band.id, name: "Band B")
        sbd = Tag(tagCategoryID: recordingType.id, name: "SBD")
        aud = Tag(tagCategoryID: recordingType.id, name: "AUD")
        secret = Tag(tagCategoryID: band.id, name: "Secret", hiddenByDefault: true)

        embeddedClip = MediaItem(
            kind: .video, relativePath: "clips/i.mp4",
            needsReview: false, parentMediaItemID: show1995.id)
        spentClipRow = MediaItem(
            kind: .video, relativePath: "clips/l.mp4",
            needsReview: false, parentMediaItemID: show1995.id, clipExported: true)

        let categories = [band, recordingType]
        let tags = [bandA, bandB, sbd, aud, secret]
        let items = [
            show1995, show1995Disc2, show2001, hiddenShow, audioOnly,
            underscoreDir, underscoreDecoy, flagged, embeddedClip,
            markedClip, exportedClip, spentClipRow,
        ]
        let tagging: [(MediaItem, Tag)] = [
            (show1995, bandA), (show1995, sbd),
            (show1995Disc2, bandA), (show1995Disc2, aud),
            (show2001, bandB),
            (hiddenShow, secret),
            (audioOnly, bandA),
        ]

        try library.writer.write { db in
            for c in categories { try c.insert(db) }
            for t in tags { try t.insert(db) }
            for i in items { try i.insert(db) }
            for (item, tag) in tagging {
                try MediaItemTag(mediaItemID: item.id, tagID: tag.id).insert(db)
            }
        }
    }

    /// File names of the visible video items for a filter — the assertion
    /// currency of the semantics tests.
    func names(_ filter: MediaFilter, kind: MediaKind = .video) throws -> Set<String> {
        Set(try library.mediaItems(matching: filter, kind: kind).map(\.fileName))
    }

    /// Every video item the empty filter shows (hidden + spent rows absent).
    var allVisibleVideoNames: Set<String> {
        ["a.mp4", "b.mp4", "c.mp4", "f.mp4", "g.mp4", "h.mp4", "i.mp4", "j.mp4", "k.mp4"]
    }
}
