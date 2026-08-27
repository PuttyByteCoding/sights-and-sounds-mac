import AVFoundation
import Foundation

/// What probing a media file yields — the file-measured half of a
/// `MediaItem`. Kept as a struct so import and future re-probe jobs share
/// one shape.
public struct ProbeResult: Sendable, Equatable {
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?
    public var videoCodec: String?
    public var audioCodec: String?
    public var frameRate: Double?
    public var bitrate: Int64?
    public var videoStreamCount: Int?
    public var audioStreamCount: Int?
    public var sampleRate: Int?
    public var audioChannels: Int?
    public var contentCreatedAt: Date?

    public init() {}
}

/// AVFoundation-based probing — the best tool for standard containers
/// (locked decision 08). Odd containers AVFoundation won't open (MKV, AVI)
/// probe empty; their rows still import with size/kind, and an
/// ffmpeg-backed fallback probe is a later, additive step.
public enum MediaProbe {
    /// File extensions the importer claims — settings-backed, defaults in
    /// `AppSettings`.
    public static var videoExtensions: Set<String> {
        Set(AppSettingsStore.shared.current.videoExtensions.map { $0.lowercased() })
    }
    public static var audioExtensions: Set<String> {
        Set(AppSettingsStore.shared.current.audioExtensions.map { $0.lowercased() })
    }

    public static func kind(forExtension ext: String) -> MediaKind? {
        kind(forExtension: ext, video: videoExtensions, audio: audioExtensions)
    }

    /// The per-library form: callers resolve the EFFECTIVE sets first
    /// (library override ?? app-wide) and pass them in — the import scan
    /// must not consult the app-wide statics behind a library's back.
    public static func kind(
        forExtension ext: String, video: Set<String>, audio: Set<String>
    ) -> MediaKind? {
        let lower = ext.lowercased()
        if video.contains(lower) { return .video }
        if audio.contains(lower) { return .audio }
        return nil
    }

    public static func probe(url: URL) async -> ProbeResult {
        var result = ProbeResult()
        let asset = AVURLAsset(url: url)

        guard let (duration, tracks, creationDate) = try? await asset.load(
            .duration, .tracks, .creationDate)
        else { return result }

        let seconds = CMTimeGetSeconds(duration)
        if seconds.isFinite, seconds > 0 { result.durationSeconds = seconds }
        result.contentCreatedAt = try? await creationDate?.load(.dateValue)

        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        result.videoStreamCount = videoTracks.count
        result.audioStreamCount = audioTracks.count

        var totalRate: Float = 0
        for track in tracks {
            if let rate = try? await track.load(.estimatedDataRate) { totalRate += rate }
        }
        if totalRate > 0 { result.bitrate = Int64(totalRate) }

        if let video = videoTracks.first {
            if let size = try? await video.load(.naturalSize) {
                result.width = Int(abs(size.width).rounded())
                result.height = Int(abs(size.height).rounded())
            }
            if let fps = try? await video.load(.nominalFrameRate), fps > 0 {
                result.frameRate = Double(fps)
            }
            if let descriptions = try? await video.load(.formatDescriptions),
               let first = descriptions.first {
                result.videoCodec = codecName(first.mediaSubType)
            }
        }
        if let audio = audioTracks.first,
           let descriptions = try? await audio.load(.formatDescriptions),
           let first = descriptions.first {
            result.audioCodec = codecName(first.mediaSubType)
            let basic = first.audioStreamBasicDescription
            if let rate = basic?.mSampleRate, rate > 0 { result.sampleRate = Int(rate) }
            if let channels = basic?.mChannelsPerFrame, channels > 0 {
                result.audioChannels = Int(channels)
            }
        }
        return result
    }

    /// FourCC → the raw lowercase codec string the schema stores.
    static func codecName(_ subType: CMFormatDescription.MediaSubType) -> String {
        switch subType {
        case .h264: "h264"
        case .hevc: "hevc"
        case CMFormatDescription.MediaSubType(rawValue: kAudioFormatMPEG4AAC): "aac"
        case CMFormatDescription.MediaSubType(rawValue: kAudioFormatFLAC): "flac"
        case CMFormatDescription.MediaSubType(rawValue: kAudioFormatMPEGLayer3): "mp3"
        case CMFormatDescription.MediaSubType(rawValue: kAudioFormatLinearPCM): "pcm"
        case CMFormatDescription.MediaSubType(rawValue: kAudioFormatAppleLossless): "alac"
        default: subType.description.trimmingCharacters(in: CharacterSet(charactersIn: "'")).lowercased()
        }
    }
}
