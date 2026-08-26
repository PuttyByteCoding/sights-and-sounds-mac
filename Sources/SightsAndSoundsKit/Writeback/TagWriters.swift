import Foundation

/// Result of one file's tag write.
public struct TagWriteResult: Sendable {
    public let success: Bool
    public let usedRemuxFallback: Bool
    public let error: String?
}

/// Writes resolved `FieldWrite`s into a file's embedded tags — ported
/// tool ladder: the format-native tool first (metaflac / AtomicParsley,
/// both rewrite tags in place without touching the essence), then an
/// ffmpeg stream-copy remux fallback (`-c copy`: only the container's
/// metadata changes). ffprobe (ships with ffmpeg) reads tags for
/// snapshots and verification.
public enum TagWriters {
    // MARK: - Tool probes

    static func toolPath(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = env.split(separator: ":").map { String($0) + "/\(name)" }
        return (pathCandidates + candidates).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func ffprobePath() -> String? { toolPath("ffprobe") }
    public static func metaflacPath() -> String? { toolPath("metaflac") }
    public static func atomicParsleyPath() -> String? { toolPath("AtomicParsley") }

    // MARK: - Reading (snapshots)

    /// The file's embedded tags as JSON: `{"format": {...}, "streams": [{...}]}`
    /// — raw ffprobe tag dictionaries, the ported snapshot payload.
    public static func readTagsJSON(url: URL) throws -> String {
        guard let ffprobe = ffprobePath() else {
            throw FfmpegTool.FfmpegError(exitCode: -1, stderrTail: "ffprobe not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error", "-show_entries", "format_tags:stream_tags",
            "-of", "json", url.path,
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, let json = String(data: data, encoding: .utf8)
        else {
            throw FfmpegTool.FfmpegError(exitCode: process.terminationStatus, stderrTail: "ffprobe failed")
        }
        return json
    }

    /// Flatten a snapshot's JSON back to name→value pairs (format tags
    /// first, then stream tags; first occurrence of a name wins).
    public static func tagPairs(fromSnapshotJSON json: String) -> [(name: String, value: String)] {
        struct Probe: Decodable {
            struct Format: Decodable { let tags: [String: String]? }
            struct Stream: Decodable { let tags: [String: String]? }
            let format: Format?
            let streams: [Stream]?
        }
        guard let decoded = try? JSONDecoder().decode(Probe.self, from: Data(json.utf8)) else { return [] }
        var seen = Set<String>()
        var pairs: [(String, String)] = []
        let dictionaries = [decoded.format?.tags].compactMap { $0 }
            + (decoded.streams ?? []).compactMap(\.tags)
        for dictionary in dictionaries {
            for (name, value) in dictionary.sorted(by: { $0.key < $1.key })
            where seen.insert(name.lowercased()).inserted {
                pairs.append((name, value))
            }
        }
        return pairs
    }

    // MARK: - Writing

    /// Write fields into the file. Wipe-and-rewrite semantics (ported):
    /// the write replaces the file's tag set with exactly these fields —
    /// which is why a pre-write snapshot is mandatory upstream.
    public static func write(fields: [FieldWrite], to url: URL) -> TagWriteResult {
        let ext = url.pathExtension.lowercased()
        if ext == "flac", let metaflac = metaflacPath() {
            do {
                try runTool(metaflac, ["--remove-all-tags", url.path])
                var arguments: [String] = []
                for field in fields {
                    for value in field.values {
                        arguments.append("--set-tag=\(field.vorbisName)=\(value)")
                    }
                }
                try runTool(metaflac, arguments + [url.path])
                return TagWriteResult(success: true, usedRemuxFallback: false, error: nil)
            } catch {
                // fall through to ffmpeg
            }
        }
        if ["mp4", "m4a", "m4v", "mov"].contains(ext), let parsley = atomicParsleyPath() {
            do {
                var arguments = [url.path, "--overWrite", "--metaEnema"]
                for field in fields {
                    let value = field.values.joined(separator: "; ")
                    if field.mp4Freeform {
                        arguments += ["--rDNSatom", value, "name=\(field.vorbisName)", "domain=com.apple.iTunes"]
                    } else {
                        arguments += [parsleyFlag(for: field.mp4Atom), value]
                    }
                }
                try runTool(parsley, arguments)
                return TagWriteResult(success: true, usedRemuxFallback: false, error: nil)
            } catch {
                // fall through to ffmpeg
            }
        }
        return ffmpegRemuxWrite(fields: fields, url: url)
    }

    /// The coverage floor: an ffmpeg `-c copy` remux carrying `-metadata`
    /// pairs — exercised on every machine with ffmpeg, whatever else is
    /// installed. Temp + atomic swap; the essence is untouched by
    /// construction and the tags are recoverable from the snapshot.
    static func ffmpegRemuxWrite(fields: [FieldWrite], url: URL) -> TagWriteResult {
        guard let ffmpeg = FfmpegTool.path() else {
            return TagWriteResult(
                success: false, usedRemuxFallback: true,
                error: FfmpegTool.installHint)
        }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-tags-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: temp) }

        var arguments = ["-i", url.path, "-map", "0", "-c", "copy", "-map_metadata", "-1"]
        for field in fields {
            arguments += ["-metadata", "\(field.vorbisName)=\(field.values.joined(separator: "; "))"]
        }
        arguments.append(temp.path)
        do {
            try FfmpegTool.run(arguments, tool: ffmpeg)
            let replaced = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            guard replaced != nil else {
                return TagWriteResult(success: false, usedRemuxFallback: true, error: "atomic replace failed")
            }
            return TagWriteResult(success: true, usedRemuxFallback: true, error: nil)
        } catch {
            return TagWriteResult(success: false, usedRemuxFallback: true, error: "\(error)")
        }
    }

    private static func parsleyFlag(for atom: String) -> String {
        switch atom {
        case "©nam": "--title"
        case "©ART": "--artist"
        case "aART": "--albumArtist"
        case "©alb": "--album"
        case "©day": "--year"
        case "©gen": "--genre"
        case "trkn": "--tracknum"
        case "©wrt": "--composer"
        case "desc": "--description"
        case "©cmt": "--comment"
        default: "--comment"
        }
    }

    private static func runTool(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.suffix(300) ?? ""
            throw FfmpegTool.FfmpegError(
                exitCode: process.terminationStatus, stderrTail: String(tail))
        }
    }
}
