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
    /// Fields the file did not keep — its format has no place for them,
    /// or its muxer dropped them. The rest were written.
    let notWritten: [String]
    /// Some of them were custom fields in an MP4 written without
    /// AtomicParsley, which could have stored them.
    let atomicParsleyWouldHelp: Bool

    public init(
        success: Bool, usedRemuxFallback: Bool, error: String?, nativeToolError: String? = nil,
        notWritten: [String] = [], atomicParsleyWouldHelp: Bool = false
    ) {
        self.success = success
        self.usedRemuxFallback = usedRemuxFallback
        self.error = error
        self.nativeToolError = nativeToolError
        self.notWritten = notWritten
        self.atomicParsleyWouldHelp = atomicParsleyWouldHelp
    }

    /// Written, but none of the fields stayed: the old tags were replaced
    /// by nothing.
    func keptNothing(of fieldCount: Int) -> Bool {
        success && fieldCount > 0 && notWritten.count >= fieldCount
    }

    /// The note a written file keeps: why it took the slow path, and what
    /// it could not hold. Nil when there is nothing to say.
    var writtenNote: String? {
        var parts: [String] = []
        if let nativeToolError { parts.append("written by remux after \(nativeToolError)") }
        if !notWritten.isEmpty {
            let shown = notWritten.prefix(10).joined(separator: ", ")
            let more = notWritten.count > 10 ? " and \(notWritten.count - 10) more" : ""
            let hint = atomicParsleyWouldHelp ? " (AtomicParsley can write custom MP4 fields)" : ""
            parts.append("not kept by this file's format: \(shown)\(more)\(hint)")
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
        if Self.mp4Family.contains(ext), let parsley = tools.atomicParsley {
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
                    if field.mp4Freeform, let native = parsleyNative(name: field.vorbisName, value: value) {
                        arguments += native
                    } else if field.mp4Freeform {
                        arguments += ["--rDNSatom", value, "name=\(field.vorbisName)", "domain=com.apple.iTunes"]
                    } else {
                        arguments += parsleyArguments(forStandard: field.mp4Atom, name: field.vorbisName, value: value)
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
        //
        // Ogg is the exception: its Vorbis comments ARE the stream's
        // metadata, and its muxer writes no file-level tags at all. There
        // the stream's comments are cleared and the fields written onto
        // the audio stream — with `:g` alone the old comments stayed and
        // the new ones went nowhere, under a success.
        let isOgg = Self.oggFamily.contains(url.pathExtension.lowercased())
        var arguments = ["-i", url.path, "-map", "0", "-c", "copy",
                         isOgg ? "-map_metadata" : "-map_metadata:g", "-1"]
        // AIFF's own chunks hold only a name and an annotation; everything
        // else lives in an ID3 chunk (where Music keeps AIFF tags), which
        // the muxer writes only when asked — without it the remux stripped
        // the file's tags down to its title.
        let ext = url.pathExtension.lowercased()
        if ext == "aiff" || ext == "aif" { arguments += ["-write_id3v2", "1"] }
        let metadataFlag = isOgg ? "-metadata:s:\(Self.oggTagStream(of: url))" : "-metadata"
        // ffmpeg's MP4/MOV muxer writes only the iTunes keys it knows.
        // `-movflags use_metadata_tags` would store custom ones too, but
        // moves EVERY tag into QuickTime keys that Music and Finder do
        // not read — the title included. So the keys it writes are
        // written, and the rest are named as not written rather than
        // vanishing under a success. Decided by the muxer's own keys, not
        // by `mp4Freeform`: a snapshot restore marks every tag it does not
        // know as freeform, disc and copyright included, which the muxer
        // writes and which were wiped and not put back.
        let isMP4 = Self.mp4Family.contains(url.pathExtension.lowercased())
        func muxerKey(_ field: FieldWrite) -> String {
            // ffmpeg's generic names for standard fields: each muxer maps
            // them to its own place (TPE2/TRCK in ID3, ALBUMARTIST/
            // TRACKNUMBER in Vorbis comments, aART/trkn in MP4). Given the
            // Vorbis names instead, MP4 dropped them and ID3 put them in
            // custom TXXX frames that players do not show.
            Self.genericKeys[field.vorbisName] ?? field.vorbisName
        }
        let isMov = ext == "mov"
        // The ffmpeg tool stamps its own encoder tag (AVI: software) over
        // any given, so such a field is never kept, though its name is.
        // Not in Ogg: there the stamp goes in the vendor string.
        let stamped: Set<String> = isOgg ? [] : ext == "avi" ? ["encoder", "software"] : ["encoder"]
        let notWritten = fields.filter { field in
            let key = muxerKey(field)
            if stamped.contains(key.lowercased()) { return true }
            guard isMP4 else { return false }
            return !Self.mp4MuxerWrites(key: key, value: field.values.joined(separator: "; "), mov: isMov)
        }.map(\.vorbisName)
        // Nothing fits: known before the file is touched. Running the remux
        // anyway wiped the file's existing tags and then reported failure.
        if !fields.isEmpty, notWritten.count == fields.count {
            let shown = notWritten.prefix(10).joined(separator: ", ")
            return TagWriteResult(
                success: false, usedRemuxFallback: true,
                error: "this file's format keeps none of these fields: \(shown) — the file was left as it was")
        }
        for field in fields where !notWritten.contains(field.vorbisName) {
            let key = muxerKey(field)
            arguments += [metadataFlag, "\(key)=\(field.values.joined(separator: "; "))"]
        }
        arguments.append(temp.path)
        do {
            try FfmpegTool.run(arguments, tool: ffmpeg)
            let replaced = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            guard replaced != nil else {
                return TagWriteResult(success: false, usedRemuxFallback: true, error: "atomic replace failed")
            }
            // What the muxer actually kept, read back: a key set per
            // container can only be as good as the last measurement, and
            // most containers (.wav, .aiff, .avi, .ts) keep only a few tags
            // and dropped the rest under a success.
            let passed = fields.filter { !notWritten.contains($0.vorbisName) }
            let vorbis = isOgg || ext == "flac"
            let dropped = Self.fieldsMissing(passed, from: url, streamTags: isOgg, vorbis: vorbis, key: muxerKey)
            return TagWriteResult(
                success: true, usedRemuxFallback: true, error: nil, notWritten: notWritten + dropped,
                atomicParsleyWouldHelp: isMP4 && !isMov && !notWritten.isEmpty)
        } catch {
            return TagWriteResult(success: false, usedRemuxFallback: true, error: "\(error)")
        }
    }

    /// Standard fields ffmpeg's MOV muxer writes under a name of its own.
    static let genericKeys = ["ALBUMARTIST": "album_artist", "TRACKNUMBER": "track", "DISCNUMBER": "disc"]

    /// The keys ffmpeg's MOV muxer writes as iTunes atoms — measured with
    /// ffmpeg 9 by writing each and reading it back with ffprobe. It drops
    /// every other key (performer, sort orders, tempo, custom names).
    static let mp4MuxerWrites: Set<String> = [
        "title", "artist", "album_artist", "composer", "album", "date", "comment", "genre",
        "copyright", "grouping", "lyrics", "description", "synopsis", "show", "episode_id",
        "network", "keywords", "media_type", "hd_video", "gapless_playback", "compilation",
        "track", "disc",
        // Kept only in ISO 6709 form; plain text is dropped, and the
        // read-back after the write names it.
        "location",
    ]

    /// In a .mov the same muxer runs in QuickTime mode and keeps only
    /// these (measured the same way). AtomicParsley refuses .mov, so this
    /// is its only writer.
    static let movMuxerWrites: Set<String> = [
        "title", "artist", "album", "date", "comment", "genre", "copyright", "location",
    ]

    /// The fields that did not come back when the file's tags are read
    /// after the write: asked by presence, not value — containers reformat
    /// on read (track 07 comes back 7, a location gains decimals), and the
    /// file's old tags were all replaced, so a tag there now is the one
    /// just written. The file-level tags only (the stream's for Ogg): the
    /// remux keeps each stream's own, and a stream title must not stand in
    /// for a dropped file title. Nothing is named when the tags cannot be
    /// read: the write itself succeeded, and there is nothing to compare.
    static func fieldsMissing(
        _ fields: [FieldWrite], from url: URL, streamTags: Bool, vorbis: Bool = false,
        key: (FieldWrite) -> String
    ) -> [String] {
        struct Probe: Decodable {
            struct Tags: Decodable { let tags: [String: String]? }
            let format: Tags?
            let streams: [Tags]?
        }
        guard !fields.isEmpty, let json = try? readTagsJSON(url: url),
              let probe = try? JSONDecoder().decode(Probe.self, from: Data(json.utf8))
        else { return [] }
        let tags = streamTags
            ? (probe.streams ?? []).compactMap(\.tags)
            : [probe.format?.tags].compactMap { $0 }
        let present = Set(tags.flatMap(\.keys).map { $0.lowercased() })
        return fields.filter { field in
            let name = key(field).lowercased()
            // Read back under another name: AVI keeps an album as IPRD
            // ("product"); Vorbis comments read DESCRIPTION as "comment".
            var names = [name]
            if name == "album" { names.append("product") }
            if name == "description", vorbis { names.append("comment") }
            return !names.contains(where: present.contains)
        }.map(\.vorbisName)
    }

    /// One-byte number atoms, and number pairs. Given text the muxer stores
    /// 0 or drops the value — a category "Compilation: Summer Hits" set the
    /// compilation flag off — and still exits 0.
    static let mp4ByteKeys: Set<String> = ["media_type", "hd_video", "gapless_playback", "compilation"]
    static let mp4PairKeys: Set<String> = ["track", "disc"]

    /// Whether the muxer really stores `value` under `key` in this file.
    static func mp4MuxerWrites(key: String, value: String, mov: Bool) -> Bool {
        let key = key.lowercased()
        guard (mov ? movMuxerWrites : mp4MuxerWrites).contains(key) else { return false }
        let value = value.trimmingCharacters(in: .whitespaces)
        if mp4ByteKeys.contains(key) {
            return Int(value).map { (0...255).contains($0) } ?? false
        }
        if mp4PairKeys.contains(key) { return isNumberPair(value) }
        return true
    }

    /// Which stream an Ogg file's tags go on: its first audio stream, as
    /// readers expect, or — in a video-only .ogv, which has none — its
    /// first stream. Aimed at a missing audio stream, ffmpeg exited 0 with
    /// the old tags cleared and the new ones written nowhere.
    static func oggTagStream(of url: URL) -> String {
        guard let ffprobe = ffprobePath(),
              let output = try? ProcessRunner.run(ffprobe, [
                  "-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                  "-of", "csv=p=0", url.path,
              ]),
              output.status == 0
        else { return "a:0" }
        let audio = String(data: output.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return audio.isEmpty ? "0" : "a:0"
    }

    /// Containers whose tags live on the stream as Vorbis comments.
    static let oggFamily: Set<String> = ["ogg", "oga", "ogv", "opus", "spx"]

    /// The MP4 family: AtomicParsley writes these, and a remux of them
    /// names its iTunes keys.
    static let mp4Family: Set<String> = ["mp4", "m4a", "m4v", "mov"]

    /// Where the remux writes before the swap: on the file's own
    /// volume. The system temp folder is on the boot volume, so a library
    /// on an external drive needed the whole video's size free there, and
    /// the swap back became a cross-volume copy.
    static func remuxScratchURL(for url: URL) throws -> URL {
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        return try LibraryDatabase.workingURL(toReplace: url, fileExtension: ext)
    }

    /// A tag a snapshot restore does not know as a standard field, but
    /// that has a native iTunes atom: it goes back to that atom. Written
    /// as a custom iTunes atom instead — after `--metaEnema` had wiped the
    /// native one — Music showed no disc, copyright or grouping, and the
    /// next snapshot kept the custom spelling. Nil keeps it custom: no
    /// native atom, or a value the native one cannot hold (text for a
    /// yes/no flag), which is kept rather than lost.
    static func parsleyNative(name: String, value: String) -> [String]? {
        let value = value.trimmingCharacters(in: .whitespaces)
        // AtomicParsley reads the sort value from the argument after the
        // kind without taking it, so one starting with "-" is read as more
        // options ("-Dash Band" set a purchase date and dropped the
        // title). That value stays custom, where a dash is harmless.
        func sortOrder(_ kind: String) -> [String]? {
            value.hasPrefix("-") ? nil : ["--sortOrder", kind, value]
        }
        func flag(_ text: String) -> String? {
            switch text.lowercased() {
            case "1", "true", "yes": "true"
            case "0", "false", "no": "false"
            default: nil
            }
        }
        switch name.lowercased() {
        // Number atoms: AtomicParsley stores text as 0, or wraps a number
        // too big, and exits 0 — a value it cannot hold stays custom.
        case "disc", "discnumber": return isNumberPair(value) ? ["--disk", value] : nil
        case "track": return isNumberPair(value) ? ["--tracknum", value] : nil
        // 16 bits in AtomicParsley, whatever the atom's width: 70000 wrapped.
        case "season_number": return UInt16(value).map { ["--TVSeasonNum", String($0)] }
        case "episode_sort": return UInt16(value).map { ["--TVEpisodeNum", String($0)] }
        case "copyright": return ["--copyright", value]
        case "grouping": return ["--grouping", value]
        case "lyrics": return ["--lyrics", value]
        case "synopsis": return ["--longdesc", value]
        case "show": return ["--TVShowName", value]
        case "episode_id": return ["--TVEpisode", value]
        case "network": return ["--TVNetwork", value]
        case "keywords": return ["--keyword", value]
        case "compilation": return flag(value).map { ["--compilation", $0] }
        case "gapless_playback": return flag(value).map { ["--gapless", $0] }
        case "hd_video": return flag(value).map { ["--hdvideo", $0] }
        case "media_type": return UInt8(value).map { ["--stik", "value=\($0)"] }
        case "podcast": return flag(value).map { ["--podcastFlag", $0] }
        case "category": return ["--category", value]
        case "purchase_date": return ["--purchaseDate", value]
        case "sort_name": return sortOrder("name")
        case "sort_artist": return sortOrder("artist")
        case "sort_album": return sortOrder("album")
        case "sort_album_artist": return sortOrder("albumartist")
        case "sort_composer": return sortOrder("composer")
        case "sort_show": return sortOrder("show")
        default: return nil
        }
    }

    /// A standard field's AtomicParsley arguments. The track number goes
    /// through `--tracknum`, which stores text as 0; a value it cannot
    /// hold is kept as a custom atom instead.
    static func parsleyArguments(forStandard atom: String, name: String, value: String) -> [String] {
        if atom == "trkn", !isNumberPair(value) {
            return ["--rDNSatom", value, "name=\(name)", "domain=com.apple.iTunes"]
        }
        return [parsleyFlag(for: atom), value]
    }

    /// `n` or `n/m`, each fitting the 16 bits the track and disc atoms hold.
    static func isNumberPair(_ value: String) -> Bool {
        let parts = value.trimmingCharacters(in: .whitespaces)
            .split(separator: "/", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count)
            && parts.allSatisfy { UInt16($0) != nil }
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
