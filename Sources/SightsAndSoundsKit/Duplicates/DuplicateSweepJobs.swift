import Foundation
import GRDB

/// Flags byte-identical pairs: same non-null content hash → a pending
/// candidate. Existing rows (any status — including rejected) block
/// re-flagging via the pair's unique index.
public struct HashDuplicateSweepJob: Job {
    public static let kind = "duplicates.hashSweep"

    public init(payload: Data?) throws {}

    public func run(_ context: JobContext) async throws {
        let library = context.library
        let groups = try library.writer.read { db -> [Row] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT contentHash, COUNT(*) AS n FROM mediaItem \
                WHERE contentHash IS NOT NULL GROUP BY contentHash HAVING n > 1
                """)
        }

        var flagged = 0
        for group in groups {
            try await context.checkCancellation()
            let hash: String = group["contentHash"]
            let ids = try await library.writer.read { db -> [UUID] in
                try UUID.fetchAll(
                    db, sql: "SELECT id FROM mediaItem WHERE contentHash = ? ORDER BY id",
                    arguments: [hash])
            }
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let candidate = DuplicateCandidate(
                        itemA: ids[i], itemB: ids[j], source: .contentHash, confidence: 1.0)
                    let inserted = try await library.writer.write { db -> Bool in
                        do {
                            try candidate.insert(db)
                            return true
                        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                            return false  // pair already known (any status)
                        }
                    }
                    if inserted { flagged += 1 }
                }
            }
        }
        await context.setSummary(
            flagged == 0 ? "no new identical-file pairs" : "\(flagged) identical-file pairs flagged")
    }
}

/// Computes missing audio fingerprints via an external Chromaprint tool
/// (fpcalc). No tool installed is a *note*, not a failure — the sweep
/// succeeds with a summary telling the user how to enable it.
public struct FingerprintCaptureJob: Job {
    public static let kind = "fingerprints.capture"

    let fileAccess: any FileAccess

    public init(payload: Data?) throws {
        fileAccess = LiveFileAccess()
    }

    /// Locate fpcalc: PATH, then the Homebrew locations.
    public static func fpcalcPath() -> String? {
        let candidates = ["/opt/homebrew/bin/fpcalc", "/usr/local/bin/fpcalc"]
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = env.split(separator: ":").map { String($0) + "/fpcalc" }
        return (pathCandidates + candidates).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func run(_ context: JobContext) async throws {
        guard let tool = Self.fpcalcPath() else {
            await context.setSummary("no fingerprint tool — brew install chromaprint to enable")
            return
        }
        let library = context.library
        let sources = try await library.writer.read { db -> [UUID: Source] in
            Dictionary(uniqueKeysWithValues: try Source.fetchAll(db).map { ($0.id, $0) })
        }
        let online = Set(
            sources.values.filter { $0.enabled && $0.isOnline(using: fileAccess) }.map(\.id))

        let pending = try await library.writer.read { db -> [MediaItem] in
            try MediaItem.fetchAll(
                db,
                sql: """
                SELECT mediaItem.* FROM mediaItem \
                WHERE NOT EXISTS (SELECT 1 FROM audioFingerprint \
                                  WHERE audioFingerprint.mediaItemID = mediaItem.id) \
                AND NOT EXISTS (SELECT 1 FROM fingerprintFailure \
                                WHERE fingerprintFailure.mediaItemID = mediaItem.id) \
                ORDER BY mediaItem.relativePath
                """)
        }.filter { online.contains($0.sourceID) }

        var computed = 0
        var failed = 0
        await context.reportProgress(current: 0, total: pending.count)

        for (index, item) in pending.enumerated() {
            try await context.checkCancellation()
            guard let source = sources[item.sourceID] else { continue }
            let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                .appendingPathComponent(item.relativePath)
            do {
                let result = try Self.runFpcalc(tool: tool, file: url)
                try await library.writer.write { db in
                    try AudioFingerprintRecord(
                        mediaItemID: item.id,
                        durationSeconds: result.duration,
                        fingerprint: AudioFingerprintRecord.pack(result.fingerprint),
                        toolVersion: result.toolVersion).upsert(db)
                }
                computed += 1
            } catch {
                try await library.writer.write { db in
                    try FingerprintFailure(mediaItemID: item.id, message: "\(error)").upsert(db)
                }
                failed += 1
            }
            await context.reportProgress(current: index + 1, total: pending.count)
        }
        await context.setSummary(
            failed == 0 ? "\(computed) fingerprinted" : "\(computed) fingerprinted, \(failed) failed")
    }

    struct FpcalcResult {
        let duration: Double
        let fingerprint: [Int32]
        let toolVersion: String
    }

    struct FpcalcError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// `fpcalc -raw -json <file>` → duration + raw sub-fingerprints.
    static func runFpcalc(tool: String, file: URL) throws -> FpcalcResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-raw", "-json", file.path]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FpcalcError(message: "fpcalc exited \(process.terminationStatus): \(stderr.prefix(200))")
        }
        // Raw sub-fingerprints are unsigned 32-bit on the wire; about half
        // of any real fingerprint exceeds Int32.max, so decode unsigned and
        // keep the bit pattern (the matcher only ever XORs them).
        struct Output: Decodable {
            let duration: Double
            let fingerprint: [UInt32]
        }
        let decoded = try JSONDecoder().decode(Output.self, from: stdout)
        return FpcalcResult(
            duration: decoded.duration,
            fingerprint: decoded.fingerprint.map { Int32(bitPattern: $0) },
            toolVersion: "fpcalc")
    }
}

/// Matches every fingerprint against every other via the calibrated
/// bucket-key prefilter, then the exact matcher — the ported thresholds
/// throughout. New matches become pending candidates for human review.
public struct FingerprintMatchSweepJob: Job {
    public static let kind = "duplicates.fingerprintSweep"

    public init(payload: Data?) throws {}

    public func run(_ context: JobContext) async throws {
        let library = context.library
        let records = try await library.writer.read { db -> [AudioFingerprintRecord] in
            try AudioFingerprintRecord.fetchAll(db)
        }
        guard records.count > 1 else {
            await context.setSummary("fewer than two fingerprints — nothing to compare")
            return
        }

        // Unpack once; distinct 14-bit bucket keys per item.
        let unpacked = records.map { (id: $0.mediaItemID, fp: $0.unpacked, duration: $0.durationSeconds) }
        let keySets = unpacked.map {
            Set(FingerprintMatcher.bucketKeys($0.fp, maskBits: FingerprintMatcher.sweepMaskBits))
        }

        let existingPairs = try await library.writer.read { db -> Set<String> in
            Set(try Row.fetchAll(db, sql: "SELECT itemAID, itemBID FROM duplicateCandidate")
                .map { "\($0["itemAID"] as UUID)|\($0["itemBID"] as UUID)" })
        }

        var flagged = 0
        let total = unpacked.count * (unpacked.count - 1) / 2
        var done = 0
        for i in 0..<unpacked.count {
            for j in (i + 1)..<unpacked.count {
                done += 1
                if done % 50 == 0 {
                    try await context.checkCancellation()
                    await context.reportProgress(current: done, total: total)
                }
                // Prefilter: shared keys relative to the smaller key set.
                let shared = keySets[i].intersection(keySets[j]).count
                let threshold = FingerprintMatcher.sweepThreshold(
                    distinctA: keySets[i].count, distinctB: keySets[j].count)
                guard shared >= threshold else { continue }

                guard let match = FingerprintMatcher.match(
                    unpacked[i].fp, durationA: unpacked[i].duration,
                    unpacked[j].fp, durationB: unpacked[j].duration)
                else { continue }

                let candidate = DuplicateCandidate(
                    itemA: unpacked[i].id, itemB: unpacked[j].id,
                    source: .fingerprint,
                    confidence: match.similarity,
                    offsetSeconds: match.offsetSeconds,
                    matchKind: match.isContainment ? .containment : .sameRecording)
                let pairKey = "\(candidate.itemAID)|\(candidate.itemBID)"
                guard !existingPairs.contains(pairKey) else { continue }

                try await library.writer.write { db in
                    try candidate.insert(db)
                }
                flagged += 1
            }
        }
        await context.setSummary(
            flagged == 0 ? "no new fingerprint matches" : "\(flagged) fingerprint matches flagged")
    }
}
