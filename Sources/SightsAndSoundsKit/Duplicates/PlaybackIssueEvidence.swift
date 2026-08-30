import Foundation
import GRDB

/// What the file said at the moment it failed.
///
/// Re-probing at review time answers a different question than the one
/// that failed: the drive may have woken up, the file may have been
/// touched, and a clean probe today does not mean the playback attempt
/// three weeks ago was fine. So the probe output is captured when the
/// issue is flagged and kept beside the item — feature state lives beside
/// the feature, not on the core row.
public struct PlaybackIssueEvidence: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "playbackIssueEvidence"

    public var mediaItemID: UUID
    public var capturedAt: Date
    /// Raw probe output — stderr and all. Shown verbatim; the point is
    /// the exact words, which is what you paste into a search.
    public var probeOutput: String
    /// A coarse classification used to match repair recipes. Nil when
    /// nothing in the output matched a known signature.
    public var failureKind: String?

    public init(
        mediaItemID: UUID, capturedAt: Date = Date(),
        probeOutput: String, failureKind: String? = nil
    ) {
        self.mediaItemID = mediaItemID
        self.capturedAt = capturedAt
        self.probeOutput = probeOutput
        self.failureKind = failureKind
    }
}

/// The coarse failure kinds recipes match on. Deliberately few: a
/// classification nobody can predict is worse than none.
public enum PlaybackFailureKind: String, Sendable, CaseIterable {
    /// `moov atom not found` — the index is at the end of an
    /// interrupted write, or missing entirely.
    case missingIndex
    /// Truncated or otherwise short file.
    case truncated
    /// The container parses but a stream does not decode.
    case badStream
    /// Nothing matched a known signature.
    case unknown

    public var displayName: String {
        switch self {
        case .missingIndex: "Missing or misplaced index"
        case .truncated: "Truncated file"
        case .badStream: "Undecodable stream"
        case .unknown: "Unclassified"
        }
    }

    /// Classify probe output. Substring matching on purpose: ffmpeg's
    /// messages are stable strings, and a regular expression here would
    /// be a second thing to get wrong.
    public static func classify(_ output: String) -> PlaybackFailureKind {
        let text = output.lowercased()
        if text.contains("moov atom not found") || text.contains("could not find codec parameters") {
            return .missingIndex
        }
        if text.contains("truncat") || text.contains("unexpected end of file")
            || text.contains("invalid data found when processing input") {
            return .truncated
        }
        if text.contains("error while decoding") || text.contains("no frame")
            || text.contains("non-existing pps") {
            return .badStream
        }
        return .unknown
    }
}

extension LibraryDatabase {
    /// Capture the file's probe output as the evidence for this issue.
    /// Called when the flag is set, not when the queue is opened.
    @discardableResult
    public func capturePlaybackIssueEvidence(
        itemID: UUID, fileAccess: any FileAccess = LiveFileAccess()
    ) throws -> PlaybackIssueEvidence? {
        guard let item = try writer.read({ try MediaItem.fetchOne($0, key: itemID) }),
              let url = try resolvedFileURL(for: item, fileAccess: fileAccess)
        else { return nil }
        let output = ProbeOutput.capture(url: url)
        let evidence = PlaybackIssueEvidence(
            mediaItemID: itemID,
            probeOutput: output,
            failureKind: PlaybackFailureKind.classify(output).rawValue)
        try writer.write { try evidence.upsert($0) }
        return evidence
    }

    public func playbackIssueEvidence(of itemID: UUID) throws -> PlaybackIssueEvidence? {
        try writer.read { db in
            try PlaybackIssueEvidence
                .filter(sql: "mediaItemID = ?", arguments: [itemID])
                .fetchOne(db)
        }
    }
}

/// Runs ffprobe and keeps everything it said.
enum ProbeOutput {
    static func capture(url: URL) -> String {
        guard let ffprobe = TagWriters.ffprobePath() else {
            return "ffprobe not found — brew install ffmpeg to capture playback evidence"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        // `-v error` keeps the banner out and the complaints in, which is
        // the half worth reading.
        process.arguments = ["-v", "error", "-show_format", "-show_streams", url.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = [
                String(data: errors, encoding: .utf8) ?? "",
                String(data: output, encoding: .utf8) ?? "",
            ].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "ffprobe reported nothing — the file opened cleanly." : text
        } catch {
            return "ffprobe could not run: \(error)"
        }
    }
}
