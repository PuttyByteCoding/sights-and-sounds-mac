import Foundation

/// Result of one file's tag write.
public struct TagWriteResult: Sendable {
    public let success: Bool
    public let usedRemuxFallback: Bool
    public let error: String?
    /// What the format-native tool said when it failed and the write
    /// fell through to the remux — kept whether or not the remux then
    /// succeeded, so "why did this file take the slow path" has an answer.
    public let nativeToolError: String?

    public init(
        success: Bool, usedRemuxFallback: Bool, error: String?, nativeToolError: String? = nil
    ) {
        self.success = success
        self.usedRemuxFallback = usedRemuxFallback
        self.error = error
        self.nativeToolError = nativeToolError
    }
}

/// Writes resolved `FieldWrite`s into a file's embedded tags — ported
/// tool ladder: the format-native tool first (metaflac / AtomicParsley,
/// both rewrite tags in place without touching the essence), then an
/// ffmpeg stream-copy remux fallback (`-c copy`: only the container's
/// metadata changes). ffprobe (ships with ffmpeg) reads tags for
/// snapshots and verification.
public enum TagWriters {
    // MARK: - Tool probes

    public static func toolPath(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = env.split(separator: ":").map { String($0) + "/\(name)" }
        return (pathCandidates + candidates).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func ffprobePath() -> String? { toolPath("ffprobe") }
    public static func metaflacPath() -> String? { toolPath("metaflac") }
    public static func atomicParsleyPath() -> String? { toolPath("AtomicParsley") }

    /// The tools one write may use. Detected from the machine by default;
    /// a test hands in stand-ins.
    public struct Tools: Sendable {
        public var metaflac: String?
        public var atomicParsley: String?
        public var ffmpeg: String?

        public init(metaflac: String?, atomicParsley: String?, ffmpeg: String?) {
            self.metaflac = metaflac
            self.atomicParsley = atomicParsley
            self.ffmpeg = ffmpeg
        }

        public static var detected: Tools {
            Tools(
                metaflac: metaflacPath(), atomicParsley: atomicParsleyPath(),
                ffmpeg: FfmpegTool.path())
        }
    }

    // MARK: - Reading (snapshots)

    /// The file's embedded tags as JSON: `{"format": {...}, "streams": [{...}]}`
    /// — raw ffprobe tag dictionaries, the ported snapshot payload.
    public static func readTagsJSON(url: URL) throws -> String {
        guard let ffprobe = ffprobePath() else {
            throw FfmpegTool.FfmpegError(exitCode: -1, stderrTail: "ffprobe not found")
        }
        let output = try ProcessRunner.run(ffprobe, [
            "-v", "error", "-show_entries", "format_tags:stream_tags",
            "-of", "json", url.path,
        ])
        guard output.status == 0, let json = String(data: output.stdout, encoding: .utf8)
        else {
            throw FfmpegTool.FfmpegError(exitCode: output.status, stderrTail: "ffprobe failed")
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
    public static func write(
        fields: [FieldWrite], to url: URL, tools: Tools = .detected
    ) -> TagWriteResult {
        let ext = url.pathExtension.lowercased()
        var nativeToolError: String?
        if ext == "flac", let metaflac = tools.metaflac {
            do {
                // One invocation, wipe then set: metaflac checks every
                // operation before it touches the file and writes the
                // result once. As two runs, a rewrite that failed (or an
                // app that quit in between) left the file with no tags.
                var arguments = ["--remove-all-tags"]
                for field in fields {
                    for value in field.values {
                        arguments.append("--set-tag=\(field.vorbisName)=\(value)")
                    }
                }
                try runTool(metaflac, arguments + [url.path])
                return TagWriteResult(success: true, usedRemuxFallback: false, error: nil)
            } catch {
                nativeToolError = "metaflac: \(error)"  // then fall through to ffmpeg
            }
        }
        if ["mp4", "m4a", "m4v", "mov"].contains(ext), let parsley = tools.atomicParsley {
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
                nativeToolError = "AtomicParsley: \(error)"  // then fall through to ffmpeg
            }
        }
        let remux = ffmpegRemuxWrite(fields: fields, url: url, ffmpeg: tools.ffmpeg)
        guard let nativeToolError else { return remux }
        AppLog.shared.warning("writeback", "\(url.lastPathComponent): \(nativeToolError)")
        return TagWriteResult(
            success: remux.success, usedRemuxFallback: true,
            error: remux.error.map { "\($0) (after \(nativeToolError))" },
            nativeToolError: nativeToolError)
    }

    /// The coverage floor: an ffmpeg `-c copy` remux carrying `-metadata`
    /// pairs — exercised on every machine with ffmpeg, whatever else is
    /// installed. Temp + atomic swap; the essence is untouched by
    /// construction and the tags are recoverable from the snapshot.
    static func ffmpegRemuxWrite(
        fields: [FieldWrite], url: URL, ffmpeg: String? = FfmpegTool.path()
    ) -> TagWriteResult {
        guard let ffmpeg else {
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

    /// metaflac names the problem first and then prints its usage text,
    /// so the end of its output alone says nothing; keep both ends.
    static func excerpt(of output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 400 else { return trimmed }
        return "\(trimmed.prefix(200)) … \(trimmed.suffix(200))"
    }

    private static func runTool(_ tool: String, _ arguments: [String]) throws {
        let output = try ProcessRunner.run(tool, arguments, captureStdout: false)
        guard output.status == 0 else {
            throw FfmpegTool.FfmpegError(
                exitCode: output.status, stderrTail: excerpt(of: output.stderrText))
        }
    }
}
