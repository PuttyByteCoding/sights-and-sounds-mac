import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Where a candidate was found, and what accepting it actually writes.
@Suite struct CandidateEvidenceTests {

    private func makeLibrary() async throws -> (LibraryDatabase, Source, TagCategory) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Evidence")
        let source = Source(name: "S", rootPath: "/tmp/evidence")
        let category = TagCategory(name: "Artist")
        try await library.writer.write { db in
            try source.insert(db)
            try category.insert(db)
        }
        return (library, source, category)
    }

    @discardableResult
    private func insertItem(
        _ library: LibraryDatabase, _ source: Source, path: String
    ) async throws -> MediaItem {
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    private func candidate(_ library: LibraryDatabase, _ value: String) throws -> TagCandidate {
        try #require(try library.tagCandidates().first { $0.value == value })
    }

    @Test func onScreenEvidenceCarriesTheEarliestReadTime() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try await library.writer.write { db in
            try OcrTextLine(mediaItemID: item.id, timeSeconds: 90, text: "Newport").insert(db)
            try OcrTextLine(mediaItemID: item.id, timeSeconds: 12, text: "Newport").insert(db)
        }

        let evidence = try library.candidateEvidence(for: try candidate(library, "Newport"))
        #expect(evidence.count == 1)
        // The earliest reading: any single moment would do, but the first
        // is reproducible when the still is generated again later.
        #expect(evidence.first?.timeSeconds == 12)
    }

    @Test func metadataAndPathEvidenceCarryNoTime() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "Concerts/a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "Bill Evans")])

        let metadata = try library.candidateEvidence(for: try candidate(library, "Bill Evans"))
        #expect(metadata.first?.timeSeconds == nil)
        let path = try library.candidateEvidence(for: try candidate(library, "Concerts"))
        #expect(path.first?.item.id == item.id)
        #expect(path.first?.timeSeconds == nil)
    }

    @Test func pathEvidenceMatchesSegmentsNotSubstrings() async throws {
        let (library, source, _) = try await makeLibrary()
        let live = try await insertItem(library, source, path: "live/a.mp4")
        try await insertItem(library, source, path: "Olive Grove/b.mp4")

        // "live" is a segment of the first path and a substring of the
        // second. Segmenting through the sub-parser is what keeps them
        // apart; matching the raw string would not.
        let evidence = try library.candidateEvidence(for: try candidate(library, "live"))
        #expect(evidence.map(\.item.id) == [live.id])
    }

    @Test func acceptingACandidateTagsEveryMatchingItem() async throws {
        let (library, source, category) = try await makeLibrary()
        let a = try await insertItem(library, source, path: "a.mp4")
        let b = try await insertItem(library, source, path: "b.mp4")
        for item in [a, b] {
            try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "Bill Evans")])
        }

        let updated = try library.apply(
            try candidate(library, "Bill Evans"), .assignCategory(categoryID: category.id))
        #expect(updated == 2)

        for item in [a, b] {
            let names = try library.tags(of: item.id).flatMap(\.tags).map(\.name)
            #expect(names == ["Bill Evans"])
        }
        // And it is gone from the queue — twice over: it now names a tag,
        // and the decision was recorded.
        #expect(try library.tagCandidates().isEmpty)
    }

    @Test func aliasingRetagsNothingButStillClearsTheQueue() async throws {
        let (library, source, category) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        let tag = Tag(tagCategoryID: category.id, name: "Bill Evans")
        try await library.writer.write { try tag.insert($0) }
        try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "W. Evans")])

        let updated = try library.apply(try candidate(library, "W. Evans"), .alias(ofTag: tag.id))
        #expect(updated == 0)
        #expect(try library.tags(of: item.id).isEmpty)  // nothing retagged

        // Excluded because it is now a known name — NOT because a decision
        // was recorded, so removing the alias brings it back.
        #expect(try library.tagCandidates().isEmpty)
        try library.removeAlias("W. Evans", fromTag: tag.id)
        #expect(try library.tagCandidates().count == 1)
    }

    @Test func itemsAffectedCountsSharedItemsOnce() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("artist", "Bill Evans"), ("album", "Portrait in Jazz"),
        ])

        let both = try library.tagCandidates()
        #expect(both.count == 2)
        // Summing the rows' counts would say 2. One item is the truth —
        // overstating the blast radius is what the bulk bar must not do.
        #expect(try library.itemsAffected(by: both) == 1)
    }

    @Test func evidenceIsBoundedByTheLimit() async throws {
        let (library, source, _) = try await makeLibrary()
        for index in 0..<10 {
            let item = try await insertItem(library, source, path: "\(index).mp4")
            try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "Bill Evans")])
        }

        let candidate = try candidate(library, "Bill Evans")
        #expect(candidate.itemCount == 10)  // the row still says ten
        #expect(try library.candidateEvidence(for: candidate, limit: 6).count == 6)
    }
}

/// Scoping the queue to a set of items — one video, or the play queue.
@Suite struct CandidateScopeTests {

    private func makeLibrary() async throws -> (LibraryDatabase, Source, TagCategory) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Scope")
        let source = Source(name: "S", rootPath: "/tmp/scope")
        let category = TagCategory(name: "Artist")
        try await library.writer.write { db in
            try source.insert(db)
            try category.insert(db)
        }
        return (library, source, category)
    }

    @discardableResult
    private func insertItem(
        _ library: LibraryDatabase, _ source: Source, path: String
    ) async throws -> MediaItem {
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    @Test func scopeNarrowsCandidatesAndCountsWithinIt() async throws {
        let (library, source, _) = try await makeLibrary()
        let inside = try await insertItem(library, source, path: "a.mp4")
        let outside = try await insertItem(library, source, path: "b.mp4")
        for item in [inside, outside] {
            try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "Miles Davis")])
        }
        try library.recordMetadataPairs(itemID: outside.id, pairs: [
            ("artist", "Miles Davis"), ("album", "Kind of Blue"),
        ])

        let scoped = try library.tagCandidates(sources: [.metadata], within: [inside.id])
        // Only strings from the scoped item, counted inside the scope:
        // Miles Davis is in two items, but the answer to "what is in THIS
        // video" is one.
        #expect(scoped.map(\.value) == ["Miles Davis"])
        #expect(scoped.first?.itemCount == 1)
    }

    @Test func pathScopeCountsOnlyScopedItemsUnderTheFolder() async throws {
        let (library, source, _) = try await makeLibrary()
        let inside = try await insertItem(library, source, path: "Concerts/a.mp4")
        try await insertItem(library, source, path: "Concerts/b.mp4")

        let scoped = try library.tagCandidates(sources: [.path], within: [inside.id])
        let concerts = try #require(scoped.first { $0.value == "Concerts" })
        #expect(concerts.itemCount == 1)
    }

    @Test func emptyScopeMeansTheWholeLibrary() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "Bill Evans")])

        // An empty set is nobody's question — it must not mean "match
        // nothing" and blank the window.
        #expect(try library.tagCandidates(sources: [.metadata], within: []).count == 1)
        #expect(try library.tagCandidates(sources: [.metadata], within: nil).count == 1)
    }

    @Test func scopedEvidenceAndAffectedCountStayInsideTheScope() async throws {
        let (library, source, _) = try await makeLibrary()
        let inside = try await insertItem(library, source, path: "a.mp4")
        let outside = try await insertItem(library, source, path: "b.mp4")
        for item in [inside, outside] {
            try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "Bill Evans")])
        }

        let candidate = try #require(
            try library.tagCandidates(sources: [.metadata], within: [inside.id]).first)
        let evidence = try library.candidateEvidence(for: candidate, within: [inside.id])
        #expect(evidence.map(\.item.id) == [inside.id])
        #expect(try library.itemsAffected(by: [candidate], within: [inside.id]) == 1)
    }

    @Test func scopedAcceptTagsOnlyScopedItemsAndSuppressesNothingGlobally() async throws {
        let (library, source, category) = try await makeLibrary()
        let inside = try await insertItem(library, source, path: "a.mp4")
        let outside = try await insertItem(library, source, path: "b.mp4")
        for item in [inside, outside] {
            try library.recordMetadataPairs(itemID: item.id, pairs: [("artist", "Bill Evans")])
        }

        let candidate = try #require(
            try library.tagCandidates(sources: [.metadata], within: [inside.id]).first)
        let updated = try library.apply(
            candidate, .assignCategory(categoryID: category.id), within: [inside.id])

        #expect(updated == 1)
        #expect(try library.tags(of: inside.id).flatMap(\.tags).map(\.name) == ["Bill Evans"])
        #expect(try library.tags(of: outside.id).isEmpty)

        // No decision row was written: the string leaves the queue only
        // because it now names a tag. Deleting that tag must bring the
        // OUTSIDE item's candidate back — a global accepted row would
        // have suppressed it forever.
        let tag = try #require(try library.tags(of: inside.id).flatMap(\.tags).first)
        try library.deleteTag(tag.id)
        #expect(try library.tagCandidates(sources: [.metadata]).count == 1)
    }

    @Test func scopedIgnoreIsDeliberatelyGlobal() async throws {
        let (library, source, _) = try await makeLibrary()
        let inside = try await insertItem(library, source, path: "a.mp4")
        let outside = try await insertItem(library, source, path: "b.mp4")
        for item in [inside, outside] {
            try library.recordMetadataPairs(itemID: item.id, pairs: [("encoder", "Lavf58")])
        }

        let candidate = try #require(
            try library.tagCandidates(sources: [.metadata], within: [inside.id]).first)
        _ = try library.apply(candidate, .ignore, within: [inside.id])

        // "Not a tag" is a fact about the string, not about whichever
        // items you were looking at.
        #expect(try library.tagCandidates(sources: [.metadata]).isEmpty)
    }

    @Test func unsweptCountSeesOnlyTheScope() async throws {
        let (library, source, _) = try await makeLibrary()
        let swept = try await insertItem(library, source, path: "a.mp4")
        let unswept = try await insertItem(library, source, path: "b.mp4")
        try library.recordMetadataPairs(itemID: swept.id, pairs: [])

        #expect(try library.unsweptCount(in: [swept.id]) == 0)
        #expect(try library.unsweptCount(in: [unswept.id]) == 1)
        #expect(try library.unsweptCount(in: [swept.id, unswept.id]) == 1)
    }
}
