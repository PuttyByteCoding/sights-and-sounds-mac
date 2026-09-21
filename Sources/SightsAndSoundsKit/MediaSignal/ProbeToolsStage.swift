import Foundation

/// What ffprobe and MediaInfo add to the declared layer, when they are
/// installed: the bitrate and frame-rate modes, the encoder's name, and a
/// second opinion on scan type and colour tags from a different parser.
///
/// Both are optional. Everything they report is about the current encode,
/// so nothing downstream depends on them; their keys carry the tool's name
/// so a disagreement with AVFoundation is visible rather than overwritten.
/// They also read containers AVFoundation cannot open at all, which makes
/// this the only declared information such a file will have.
public struct ProbeToolsStage: SignalStage {
    public let name = "probeTools"
    public let version = 1
    public let kinds: Set<MediaKind> = [.video, .audio]

    let ffprobe: String?
    let mediainfo: String?

    public init(
        ffprobe: String? = TagWriters.ffprobePath(),
        mediainfo: String? = TagWriters.toolPath("mediainfo")
    ) {
        self.ffprobe = ffprobe
        self.mediainfo = mediainfo
    }

    public func examine(_ file: SignalStageInput) async throws -> SignalFindings {
        var findings = SignalFindings()
        if let ffprobe {
            let output = try await ProcessRunner.run(
                ffprobe,
                ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", file.url.path],
                isCancelled: file.isCancelled)
            if output.status == 0 { Self.readFfprobe(output.stdout, into: &findings) }
        }
        if let mediainfo {
            let output = try await ProcessRunner.run(
                mediainfo, ["--Output=JSON", file.url.path], isCancelled: file.isCancelled)
            if output.status == 0 { Self.readMediaInfo(output.stdout, into: &findings) }
        }
        // Neither tool installed is not a failure: the stage ran and had
        // nothing to add, and says which tools it looked for.
        findings.declare(
            "tools.available",
            [ffprobe != nil ? "ffprobe" : nil, mediainfo != nil ? "mediainfo" : nil]
                .compactMap { $0 }.joined(separator: " ").nonEmpty ?? "none")
        return findings
    }

    // MARK: - ffprobe

    static let ffprobeStreamKeys = [
        "codec_name", "profile", "level", "pix_fmt", "field_order", "color_range",
        "color_space", "color_transfer", "color_primaries", "chroma_location",
        "sample_aspect_ratio", "display_aspect_ratio", "r_frame_rate", "avg_frame_rate",
        "has_b_frames", "refs", "bits_per_raw_sample", "sample_fmt", "channel_layout",
    ]

    static func readFfprobe(_ json: Data, into findings: inout SignalFindings) {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
        if let format = root["format"] as? [String: Any] {
            findings.declare("ffprobe.format.name", format["format_name"] as? String)
            let tags = format["tags"] as? [String: Any]
            findings.declare("ffprobe.format.encoder", tags?["encoder"] as? String)
        }
        var seen: Set<String> = []
        for stream in root["streams"] as? [[String: Any]] ?? [] {
            // The first stream of each kind, to match what AVFoundation's
            // stage describes.
            guard let type = stream["codec_type"] as? String, ["video", "audio"].contains(type),
                  seen.insert(type).inserted
            else { continue }
            // Cover art is a video stream to ffprobe and not to anyone else.
            if let disposition = stream["disposition"] as? [String: Any],
               (disposition["attached_pic"] as? Int) == 1 {
                seen.remove(type)
                continue
            }
            for key in ffprobeStreamKeys {
                guard let value = stream[key] else { continue }
                findings.declare("ffprobe.\(type).\(key)", "\(value)")
            }
            let tags = stream["tags"] as? [String: Any]
            findings.declare("ffprobe.\(type).encoder", tags?["encoder"] as? String)
            for sideData in stream["side_data_list"] as? [[String: Any]] ?? [] {
                guard let kind = sideData["side_data_type"] as? String else { continue }
                findings.declare("ffprobe.\(type).sideData.\(kind)", "present")
            }
        }
    }

    // MARK: - MediaInfo

    static let mediaInfoKeys: [String: [String]] = [
        "General": ["Format", "Format_Profile", "Encoded_Application", "Encoded_Library", "OverallBitRate_Mode"],
        "Video": [
            "Format_Profile", "Format_Level", "Format_Tier", "BitRate_Mode", "FrameRate_Mode",
            "ScanType", "ScanOrder", "Encoded_Library_Name", "Encoded_Library_Version",
            "Encoded_Library_Settings", "HDR_Format", "Standard",
        ],
        "Audio": ["Format", "Format_AdditionalFeatures", "BitRate_Mode", "Compression_Mode"],
    ]

    static func readMediaInfo(_ json: Data, into findings: inout SignalFindings) {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let media = root["media"] as? [String: Any],
              let tracks = media["track"] as? [[String: Any]]
        else { return }
        var seen: Set<String> = []
        for track in tracks {
            guard let type = track["@type"] as? String, let keys = mediaInfoKeys[type],
                  seen.insert(type).inserted
            else { continue }
            for key in keys {
                findings.declare("mediainfo.\(type.lowercased()).\(key)", track[key] as? String)
            }
        }
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
