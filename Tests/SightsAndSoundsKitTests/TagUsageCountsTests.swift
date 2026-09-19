import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Library-wide usage in one query, for the Tag Manager's search across
/// every category: every tag counted, an unused one at zero.
@Suite struct TagUsageCountsTests {
    @Test func everyTagIsCountedAcrossCategories() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Usage")
        let source = Source(name: "S", rootPath: "/tmp/usage")
        let band = TagCategory(name: "Band")
        let venue = TagCategory(name: "Venue")
        let a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        let b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try band.insert(db)
            try venue.insert(db)
            try a.insert(db)
            try b.insert(db)
        }
        let phish = try library.ensureTag(named: "Phish", inCategory: band.id)
        let gorge = try library.ensureTag(named: "The Gorge", inCategory: venue.id)
        let unused = try library.ensureTag(named: "Unused", inCategory: venue.id)
        try library.assignTag(phish.id, to: a.id)
        try library.assignTag(phish.id, to: b.id)
        try library.assignTag(gorge.id, to: a.id)

        let counts = try library.tagUsageCounts()
        #expect(counts[phish.id] == 2)
        #expect(counts[gorge.id] == 1)
        #expect(counts[unused.id] == 0)
    }
}
