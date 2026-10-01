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
        // A stage that read the file well, with a curve, and conclusions
        // drawn from it: every Media Signal table holds a row.
        var good = SignalFindings()
        good.declare("container.writingApplication", "HandBrake 1.7.0")
        good.measure("geometry.pillarboxed", 1)
        good.measure("geometry.pillarboxFraction", 0.25)
        good.measure("geometry.activeAspectRatio", 1.333)
        good.keep("audio.spectrum", spectrum: [1, 2, 3, 4], at: nil)
        try library.recordSignalStage(itemID: item.id, stage: "declared", version: 1, findings: good)
        try MediaSignalJob.drawConclusions(for: item.id, in: library)
        try library.recordSignalStage(
            itemID: item.id, stage: "frameTiming", version: 1, findings: SignalFindings(),
            failure: "the old file's timestamps could not be read")
        return Seeded(library: library, item: item, twin: twin)
    }

    private func count(_ library: LibraryDatabase, _ sql: String, _ id: UUID) async throws -> Int {
        try await library.writer.read { try Int.fetchOne($0, sql: sql, arguments: [id]) ?? 0 }
    }

    private static let readings = [
        "mediaSignalDeclared", "mediaSignalMeasurement", "mediaSignalSeries",
        "mediaSignalEvidence", "mediaSignalInference",
    ]

    /// Rows per Media Signal table, each required to be there to begin
    /// with, so every check after can fail.
    private func readingCounts(_ s: Seeded) async throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in Self.readings + ["mediaSignalStage"] {
            counts[table] = try await count(s.library, "SELECT COUNT(*) FROM \(table) WHERE mediaItemID = ?", s.item.id)
        }
        return counts
    }

    @Test func aTagWriteForgetsTheOldBytesButKeepsWhatMediaSignalRead() async throws {
        let s = try await seeded()
        let before = try await readingCounts(s)
        for (table, rows) in before { try #require(rows > 0, "\(table) was not seeded") }
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
        #expect(try await count(s.library, "SELECT COUNT(*) FROM mediaSignalStage WHERE mediaItemID = ?", id)
                == before["mediaSignalStage"]! - 1)
        #expect(try await count(s.library, "SELECT COUNT(*) FROM mediaSignalStage WHERE mediaItemID = ? AND failureMessage IS NOT NULL", id) == 0)
        let after = try await readingCounts(s)
        for table in Self.readings {
            #expect(after[table] == before[table], "a tag write dropped \(table)")
        }
        // The twin is untouched.
        #expect(try await s.library.writer.read { try MediaItem.fetchOne($0, key: s.twin.id)?.contentHash } == "old-bytes")
    }

    @Test func newStreamsForgetEverythingMediaSignalRead() async throws {
        let s = try await seeded()
        for (table, rows) in try await readingCounts(s) { try #require(rows > 0, "\(table) was not seeded") }
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
