import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The duplicate sweeps end to end: hash pairs, fingerprint matches via
/// the calibrated prefilter, pair normalization, and the rejected-stays-
/// rejected guarantee.
@Suite struct DuplicateSweepTests {

    private func makeLibrary() async throws -> (LibraryDatabase, JobRunner, Source) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Dupes")
        let source = Source(name: "S", rootPath: "/tmp/dupes")
        try await library.writer.write { try source.insert($0) }
        let runner = JobRunner(library: library)
        await runner.register(HashDuplicateSweepJob.self)
        await runner.register(FingerprintMatchSweepJob.self)
        return (library, runner, source)
    }

    private func insertItem(
        _ library: LibraryDatabase, _ source: Source, path: String, hash: String? = nil
    ) async throws -> MediaItem {
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: path,
            contentHash: hash, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    @Test func candidatePairOrderIsNormalized() {
        let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let z = UUID(uuidString: "ZZZZZZZZ-0000-0000-0000-000000000000".replacingOccurrences(of: "Z", with: "F"))!
        let forward = DuplicateCandidate(itemA: a, itemB: z, source: .manual)
        let backward = DuplicateCandidate(itemA: z, itemB: a, source: .manual)
        #expect(forward.itemAID == backward.itemAID)
        #expect(forward.itemBID == backward.itemBID)
    }

    @Test func hashSweepFlagsIdenticalPairsOnce() async throws {
        let (library, runner, source) = try await makeLibrary()
        _ = try await insertItem(library, source, path: "a.mp4", hash: "same")
        _ = try await insertItem(library, source, path: "b.mp4", hash: "same")
        _ = try await insertItem(library, source, path: "c.mp4", hash: "different")
        _ = try await insertItem(library, source, path: "d.mp4")  // unhashed

        let job = try await runner.enqueue(HashDuplicateSweepJob.self)
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: job.id)! }
        #expect(row.summary == "1 identical-file pairs flagged")

        let candidates = try await library.writer.read { try DuplicateCandidate.fetchAll($0) }
        #expect(candidates.count == 1)
        #expect(candidates[0].source == .contentHash)
        #expect(candidates[0].status == .pending)

        // Re-run: the pair is known, nothing new.
        let again = try await runner.enqueue(HashDuplicateSweepJob.self)
        try await runner.runPending()
        let againRow = try await library.writer.read { try JobRecord.fetchOne($0, key: again.id)! }
        #expect(againRow.summary == "no new identical-file pairs")
    }

    @Test func rejectedPairIsNeverReflagged() async throws {
        let (library, runner, source) = try await makeLibrary()
        let a = try await insertItem(library, source, path: "a.mp4", hash: "same")
        let b = try await insertItem(library, source, path: "b.mp4", hash: "same")

        // Flag, then the human rejects.
        _ = try await runner.enqueue(HashDuplicateSweepJob.self)
        try await runner.runPending()
        try await library.writer.write { db in
            try db.execute(sql: "UPDATE duplicateCandidate SET status = 'rejected'")
        }

        // Sweep again: the rejected row blocks re-flagging.
        _ = try await runner.enqueue(HashDuplicateSweepJob.self)
        try await runner.runPending()
        let candidates = try await library.writer.read { try DuplicateCandidate.fetchAll($0) }
        #expect(candidates.count == 1)
        #expect(candidates[0].status == .rejected)
        _ = (a, b)
    }

    @Test func fingerprintSweepFlagsRealMatchesOnly() async throws {
        let (library, runner, source) = try await makeLibrary()
        let itemA = try await insertItem(library, source, path: "a.mp4")
        let itemB = try await insertItem(library, source, path: "b.mp4")
        let itemC = try await insertItem(library, source, path: "c.mp4")

        // A and B share content (5% corruption); C is unrelated.
        var rng = DemoVocabulary.SeededGenerator(seed: 42)
        let shared = (0..<800).map { _ in Int32(truncatingIfNeeded: rng.next()) }
        let corrupted: [Int32] = {
            var copy = shared
            copy[10] ^= 0x0F0F  // trivially different, still ≥0.999 similar
            return copy
        }()
        let unrelated = (0..<800).map { _ in Int32(truncatingIfNeeded: rng.next()) }

        try await library.writer.write { db in
            for (item, fp) in [(itemA, shared), (itemB, corrupted), (itemC, unrelated)] {
                try AudioFingerprintRecord(
                    mediaItemID: item.id, durationSeconds: 100,
                    fingerprint: AudioFingerprintRecord.pack(fp), toolVersion: "test").insert(db)
            }
        }

        let job = try await runner.enqueue(FingerprintMatchSweepJob.self)
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: job.id)! }
        #expect(row.summary == "1 fingerprint matches flagged")

        let candidates = try await library.writer.read { try DuplicateCandidate.fetchAll($0) }
        #expect(candidates.count == 1)
        #expect(candidates[0].source == .fingerprint)
        #expect(candidates[0].matchKind == .sameRecording)
        #expect((candidates[0].confidence ?? 0) > 0.99)
        // The pair is A/B in normalized order.
        let ids = Set([candidates[0].itemAID, candidates[0].itemBID])
        #expect(ids == Set([itemA.id, itemB.id]))
    }

    @Test func fingerprintSweepRespectsExistingPairs() async throws {
        let (library, runner, source) = try await makeLibrary()
        let itemA = try await insertItem(library, source, path: "a.mp4")
        let itemB = try await insertItem(library, source, path: "b.mp4")
        var rng = DemoVocabulary.SeededGenerator(seed: 43)
        let fp = (0..<800).map { _ in Int32(truncatingIfNeeded: rng.next()) }
        try await library.writer.write { db in
            try AudioFingerprintRecord(
                mediaItemID: itemA.id, durationSeconds: 100,
                fingerprint: AudioFingerprintRecord.pack(fp), toolVersion: "t").insert(db)
            try AudioFingerprintRecord(
                mediaItemID: itemB.id, durationSeconds: 100,
                fingerprint: AudioFingerprintRecord.pack(fp), toolVersion: "t").insert(db)
            // The pair already exists (say, from the hash sweep).
            try DuplicateCandidate(itemA: itemA.id, itemB: itemB.id, source: .contentHash).insert(db)
        }

        _ = try await runner.enqueue(FingerprintMatchSweepJob.self)
        try await runner.runPending()
        let candidates = try await library.writer.read { try DuplicateCandidate.fetchAll($0) }
        #expect(candidates.count == 1)  // no second row for the same pair
    }

    // MARK: Segments are not files

    /// A segment row carries its parent's path — its file IS the parent's
    /// file. A sweep that treats it as a file pairs the parent with its
    /// own songs, and resolving that pair stages the one real file.
    private func insertSegment(
        _ library: LibraryDatabase, of parent: MediaItem, hash: String? = nil
    ) async throws -> MediaItem {
        let segment = try library.createEmbeddedClip(
            parentID: parent.id, name: "Song", startSeconds: 0, endSeconds: 10, role: .song)
        if let hash {
            try await library.writer.write { db in
                try db.execute(
                    sql: "UPDATE mediaItem SET contentHash = ? WHERE id = ?",
                    arguments: [hash, segment.id])
            }
        }
        return segment
    }

    @Test func hashSweepNeverPairsAParentWithItsSegments() async throws {
        let (library, runner, source) = try await makeLibrary()
        let parent = try await insertItem(library, source, path: "show.mp4", hash: "same")
        // Rows an earlier sweep hashed: same bytes, because same file.
        _ = try await insertSegment(library, of: parent, hash: "same")
        _ = try await insertSegment(library, of: parent, hash: "same")

        let job = try await runner.enqueue(HashDuplicateSweepJob.self)
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: job.id)! }
        #expect(row.summary == "no new identical-file pairs")
        let candidates = try await library.writer.read { try DuplicateCandidate.fetchAll($0) }
        #expect(candidates.isEmpty)
    }

    @Test func fingerprintSweepIgnoresSegmentFingerprints() async throws {
        let (library, runner, source) = try await makeLibrary()
        let parent = try await insertItem(library, source, path: "show.mp4")
        let segment = try await insertSegment(library, of: parent)
        var rng = DemoVocabulary.SeededGenerator(seed: 44)
        let fp = (0..<800).map { _ in Int32(truncatingIfNeeded: rng.next()) }
        try await library.writer.write { db in
            for id in [parent.id, segment.id] {
                try AudioFingerprintRecord(
                    mediaItemID: id, durationSeconds: 100,
                    fingerprint: AudioFingerprintRecord.pack(fp), toolVersion: "t").insert(db)
            }
        }

        _ = try await runner.enqueue(FingerprintMatchSweepJob.self)
        try await runner.runPending()
        let candidates = try await library.writer.read { try DuplicateCandidate.fetchAll($0) }
        #expect(candidates.isEmpty)
    }

    @Test func fingerprintCaptureQueuesFilesNotSegments() async throws {
        let (library, _, source) = try await makeLibrary()
        let parent = try await insertItem(library, source, path: "show.mp4")
        _ = try await insertSegment(library, of: parent)

        let pending = try await library.writer.read { try FingerprintCaptureJob.pendingItems($0) }
        #expect(pending.map(\.id) == [parent.id])
    }

    @Test func sweepsClearThePairsAnEarlierSweepMadeWithSegments() async throws {
        let (library, runner, source) = try await makeLibrary()
        let parent = try await insertItem(library, source, path: "show.mp4", hash: "same")
        let segment = try await insertSegment(library, of: parent, hash: "same")
        let other = try await insertItem(library, source, path: "other.mp4")
        try await library.writer.write { db in
            // Left behind by the old sweep: pending, machine-made.
            try DuplicateCandidate(itemA: parent.id, itemB: segment.id, source: .contentHash).insert(db)
            // A pair a person made is theirs to resolve.
            try DuplicateCandidate(itemA: other.id, itemB: segment.id, source: .manual).insert(db)
        }

        _ = try await runner.enqueue(HashDuplicateSweepJob.self)
        try await runner.runPending()
        let candidates = try await library.writer.read { try DuplicateCandidate.fetchAll($0) }
        #expect(candidates.map(\.source) == [.manual])
    }

    @Test func statusCountsFilesNotSegments() async throws {
        let (library, _, source) = try await makeLibrary()
        let parent = try await insertItem(library, source, path: "show.mp4")
        _ = try await insertSegment(library, of: parent)

        #expect(try library.contentHashStatus().missing == 1)
        #expect(try library.fingerprintStatus().missing == 1)
    }

    @Test func captureJobWithoutToolIsANoteNotAFailure() async throws {
        // On machines without fpcalc the sweep succeeds with guidance.
        guard FingerprintCaptureJob.fpcalcPath() == nil else { return }
        let (library, runner, _) = try await makeLibrary()
        await runner.register(FingerprintCaptureJob.self)
        let job = try await runner.enqueue(FingerprintCaptureJob.self)
        try await runner.runPending()
        let row = try await library.writer.read { try JobRecord.fetchOne($0, key: job.id)! }
        #expect(row.state == .succeeded)
        #expect(row.summary?.contains("brew install chromaprint") == true)
    }
}

/// The fpcalc bridge: raw sub-fingerprints are unsigned 32-bit values
/// on the wire, and roughly half of any real fingerprint sits above
/// `Int32.max`. They must land as the same bit patterns the matcher
/// XORs, not as a decoding failure.
@Suite struct FpcalcOutputTests {

    /// A stand-in fpcalc: an executable script that prints the fixture
    /// and ignores its arguments.
    private func stubTool(printing json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fpcalc-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tool = dir.appendingPathComponent("fpcalc")
        let script = "#!/bin/sh\ncat <<'JSON'\n\(json)\nJSON\n"
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    @Test func valuesAboveInt32MaxDecodeAsBitPatterns() throws {
        let tool = try stubTool(printing: """
            {"duration": 2040.7, "fingerprint": [4292056688, 2146836971, 0, 4294967295]}
            """)
        defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }

        let result = try FingerprintCaptureJob.runFpcalc(
            tool: tool.path, file: URL(fileURLWithPath: "/tmp/ignored.mp4"))

        #expect(result.duration == 2040.7)
        #expect(result.fingerprint == [
            Int32(bitPattern: 4292056688), 2146836971, 0, Int32(bitPattern: 4294967295),
        ])
    }
}
