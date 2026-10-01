import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// What a change of bytes forgets, decided by the database alone: the jobs
/// that reach it need ffmpeg, metaflac or AtomicParsley, and CI does not
/// have them all, so a change to these rules could otherwise pass there
/// untested.
@Suite struct ChangedFileTests {
    private struct Seeded {
        let library: LibraryDatabase
        let item: MediaItem
        let twin: MediaItem
    }

    private func seeded() async throws -> Seeded {
        let library = try LibraryDatabase.openInMemory()
        let source = Source(name: "S", rootPath: "/tmp/sas-changed-\(UUID().uuidString)")
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", fileSize: 1,
                             contentHash: "old-bytes", needsReview: false)
        let twin = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", fileSize: 1,
                             contentHash: "old-bytes", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
            try twin.insert(db)
            try ContentHashFailure(mediaItemID: item.id, message: "timed out").insert(db)
            try MetadataSweepState(mediaItemID: item.id, failureMessage: nil).insert(db)
            try FingerprintFailure(mediaItemID: item.id, message: "fpcalc could not decode").insert(db)
            try ThumbnailState(mediaItemID: item.id, generated: false, failureMessage: "no frame").upsert(db)
            try DuplicateCandidate(itemA: item.id, itemB: twin.id, source: .contentHash, confidence: 1).insert(db)
        }
        var good = SignalFindings()
        good.declare("video.codecTag", "avc1")
        good.measure("timing.frameCount", 10)
        try library.recordSignalStage(itemID: item.id, stage: "declared", version: 1, findings: good)
        try library.recordSignalStage(
            itemID: item.id, stage: "frameTiming", version: 1, findings: SignalFindings(),
            failure: "the old file's timestamps could not be read")
        return Seeded(library: library, item: item, twin: twin)
    }

    private func count(_ library: LibraryDatabase, _ sql: String, _ id: UUID) async throws -> Int {
        try await library.writer.read { try Int.fetchOne($0, sql: sql, arguments: [id]) ?? 0 }
    }

    @Test func aTagWriteForgetsTheOldBytesButKeepsWhatMediaSignalRead() async throws {
        let s = try await seeded()
        try await s.library.writer.write { db in
            try LibraryDatabase.forgetReadingsOfChangedFile(s.item.id, .sameStreams, in: db)
        }
        let id = s.item.id
        #expect(try await s.library.writer.read { try MediaItem.fetchOne($0, key: id)?.contentHash } == nil)
        #expect(try await count(s.library, "SELECT COUNT(*) FROM contentHashFailure WHERE mediaItemID = ?", id) == 0)
        #expect(try await count(s.library, "SELECT COUNT(*) FROM metadataSweepState WHERE mediaItemID = ?", id) == 0)
        #expect(try await count(s.library, "SELECT COUNT(*) FROM fingerprintFailure WHERE mediaItemID = ?", id) == 0)
        #expect(try await count(s.library, "SELECT COUNT(*) FROM thumbnailState WHERE mediaItemID = ?", id) == 0)
        #expect(try await count(s.library, "SELECT COUNT(*) FROM duplicateCandidate WHERE itemAID = ? OR itemBID = ?1", id) == 0)
        // The stage that read the same streams stays; the one that failed goes.
        #expect(try await count(s.library, "SELECT COUNT(*) FROM mediaSignalStage WHERE mediaItemID = ?", id) == 1)
        #expect(try await count(s.library, "SELECT COUNT(*) FROM mediaSignalStage WHERE mediaItemID = ? AND failureMessage IS NOT NULL", id) == 0)
        #expect(try await count(s.library, "SELECT COUNT(*) FROM mediaSignalDeclared WHERE mediaItemID = ?", id) == 1)
        #expect(try await count(s.library, "SELECT COUNT(*) FROM mediaSignalMeasurement WHERE mediaItemID = ?", id) == 1)
        // The twin is untouched.
        #expect(try await s.library.writer.read { try MediaItem.fetchOne($0, key: s.twin.id)?.contentHash } == "old-bytes")
    }

    @Test func newStreamsForgetEverythingMediaSignalRead() async throws {
        let s = try await seeded()
        try await s.library.writer.write { db in
            try LibraryDatabase.forgetReadingsOfChangedFile(s.item.id, .newStreams, in: db)
        }
        let id = s.item.id
        for table in ["mediaSignalStage", "mediaSignalDeclared", "mediaSignalMeasurement",
                      "mediaSignalSeries", "mediaSignalEvidence", "mediaSignalInference"] {
            #expect(try await count(s.library, "SELECT COUNT(*) FROM \(table) WHERE mediaItemID = ?", id) == 0, "\(table)")
        }
        #expect(try await count(s.library, "SELECT COUNT(*) FROM fingerprintFailure WHERE mediaItemID = ?", id) == 0)
        #expect(try await count(s.library, "SELECT COUNT(*) FROM metadataSweepState WHERE mediaItemID = ?", id) == 0)
    }
}
