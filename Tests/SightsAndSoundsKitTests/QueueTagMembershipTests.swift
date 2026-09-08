import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The rail's raw material: which tags each of a given set of items
/// wears — every asked-for item present, nothing else.
@Suite struct QueueTagMembershipTests {
    @Test func everyAskedForItemIsPresentAndOnlyThose() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Membership")
        let source = Source(name: "S", rootPath: "/tmp/m-\(UUID().uuidString)")
        let band = TagCategory(name: "Band")
        let phish = Tag(tagCategoryID: band.id, name: "Phish")
        let sbd = Tag(tagCategoryID: band.id, name: "Soundboard")
        let a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        let b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", needsReview: false)
        let other = MediaItem(sourceID: source.id, kind: .video, relativePath: "o.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db); try band.insert(db); try phish.insert(db); try sbd.insert(db)
            try a.insert(db); try b.insert(db); try other.insert(db)
        }
        try library.assignTag(phish.id, to: a.id)
        try library.assignTag(sbd.id, to: a.id)
        try library.assignTag(phish.id, to: other.id)

        let membership = try library.tagIDsByItem(forItems: [a.id, b.id])
        #expect(membership[a.id] == [phish.id, sbd.id])
        #expect(membership[b.id] == [])
        #expect(membership[other.id] == nil)
        #expect(try library.tagIDsByItem(forItems: []).isEmpty)
    }
}
