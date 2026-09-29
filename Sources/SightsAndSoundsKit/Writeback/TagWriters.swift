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
    /// Fields the writer could not store in this file — custom fields in
    /// an MP4 written without AtomicParsley. The rest were written.
    let notWritten: [String]

    public init(
        success: Bool, usedRemuxFallback: Bool, error: String?, nativeToolError: String? = nil,
        notWritten: [String] = []
    ) {
        self.success = success
        self.usedRemuxFallback = usedRemuxFallback
        self.error = error
        self.nativeToolError = nativeToolError
        self.notWritten = notWritten
    }

    /// The note a written file keeps: why it took the slow path, and what
    /// it could not hold. Nil when there is nothing to say.
    var writtenNote: String? {
        var parts: [String] = []
        if let nativeToolError { parts.append("written by remux after \(nativeToolError)") }
        if !notWritten.isEmpty {
            parts.append("not written (MP4 custom fields need AtomicParsley): "
                + notWritten.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
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
            // `--metaEnema` is what makes this a wipe-and-rewrite, and it
            // wipes the cover art with everything else. The library does
            // not hold the art and snapshots do not record it, so it is
            // lifted out first and handed back in the same invocation —
            // the file is only ever rewritten once, with its art in it.
            let artDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-cover-art-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: artDirectory) }
            do {
                var arguments = [url.path, "--overWrite", "--metaEnema"]
                for art in try extractCoverArt(from: url, into: artDirectory, tool: parsley) {
                    arguments += ["--artwork", art.path]
                }
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
            nativeToolError: nativeToolError, notWritten: remux.notWritten)
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
        let temp: URL
        do { temp = try remuxScratchURL(for: url) } catch {
            return TagWriteResult(success: false, usedRemuxFallback: true, error: "\(error)")
        }
        // The scratch file, then its folder only if that is now empty —
        // rmdir refuses anything else, so a shared folder is never touched.
        defer {
            try? FileManager.default.removeItem(at: temp)
            rmdir(temp.deletingLastPathComponent().path)
        }

        // `:g` — the FILE's tags are replaced; each stream keeps its own
        // (languages, track titles, handler names), which a plain
        // `-map_metadata -1` wiped and the snapshot cannot put back.
        var arguments = ["-i", url.path, "-map", "0", "-c", "copy", "-map_metadata:g", "-1"]
        // ffmpeg's MP4/MOV muxer writes only the iTunes keys it knows.
        // `-movflags use_metadata_tags` would store custom ones too, but
        // moves EVERY tag into QuickTime keys that Music and Finder do
        // not read — the title included. So the known fields are
        // written, and the custom ones are named as not written rather
        // than vanishing under a success.
        let isMP4 = ["mp4", "m4v", "m4a", "mov"].contains(url.pathExtension.lowercased())
        let notWritten = isMP4 ? fields.filter(\.mp4Freeform).map(\.vorbisName) : []
        for field in fields where !notWritten.contains(field.vorbisName) {
            arguments += ["-metadata", "\(field.vorbisName)=\(field.values.joined(separator: "; "))"]
        }
        arguments.append(temp.path)
        do {
            try FfmpegTool.run(arguments, tool: ffmpeg)
            let replaced = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            guard replaced != nil else {
                return TagWriteResult(success: false, usedRemuxFallback: true, error: "atomic replace failed")
            }
            return TagWriteResult(
                success: true, usedRemuxFallback: true, error: nil, notWritten: notWritten)
        } catch {
            return TagWriteResult(success: false, usedRemuxFallback: true, error: "\(error)")
        }
    }

    /// Where the remux writes before the swap: on the file's own
    /// volume. The system temp folder is on the boot volume, so a library
    /// on an external drive needed the whole video's size free there, and
    /// the swap back became a cross-volume copy.
    static func remuxScratchURL(for url: URL) throws -> URL {
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        return try LibraryDatabase.workingURL(toReplace: url, fileExtension: ext)
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

    /// The file's cover images, written out in the order the file holds
    /// them. None is an empty list; a tool failure throws, which sends the
    /// write to the ffmpeg remux — that keeps art without being asked.
    private static func extractCoverArt(from url: URL, into directory: URL, tool: String) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = directory.appendingPathComponent("cover")
        try runTool(tool, [url.path, "--extractPixToPath", prefix.path])
        // cover_artwork_1.png, cover_artwork_2.jpg, …
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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
