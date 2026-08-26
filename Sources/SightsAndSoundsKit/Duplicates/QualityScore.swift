import Foundation

/// One labeled slice of a quality score. A zero-max component is an
/// ANNOTATION — it shows a raw value or an absence for a human to eyeball
/// and contributes nothing to the total.
public struct ScoreComponent: Sendable, Equatable {
    public let label: String
    public let points: Double
    public let maxPoints: Double
    public let note: String?

    public init(_ label: String, _ points: Double, _ maxPoints: Double, _ note: String? = nil) {
        self.label = label
        self.points = points
        self.maxPoints = maxPoints
        self.note = note
    }
}

public struct QualityScoreResult: Sendable, Equatable {
    /// 0–100, scaled over the applicable components.
    public let total: Double
    public let components: [ScoreComponent]
}

/// Expensive per-file signal metrics (ffmpeg analysis). Capture arrives
/// with a later job; the score composition already handles their absence
/// by design — this struct exists so the plumbing is complete now.
public struct QualityAnalysisMetrics: Sendable, Equatable {
    public var audioRolloffHz: Double?
    public var audioPeakDb: Double?
    public var audioRmsDb: Double?
    public var videoBlockiness: Double?
    public var videoBlurriness: Double?
    public var analysisFailed: Bool

    public init(
        audioRolloffHz: Double? = nil, audioPeakDb: Double? = nil, audioRmsDb: Double? = nil,
        videoBlockiness: Double? = nil, videoBlurriness: Double? = nil, analysisFailed: Bool = false
    ) {
        self.audioRolloffHz = audioRolloffHz
        self.audioPeakDb = audioPeakDb
        self.audioRmsDb = audioRmsDb
        self.videoBlockiness = videoBlockiness
        self.videoBlurriness = videoBlurriness
        self.analysisFailed = analysisFailed
    }
}

/// Pure quality-score composition for the compare view — ported from the
/// old app's `QualityScore`, tier tables and all.
///
/// The total is ALWAYS scaled — Σpoints / Σmax × 100 — never a raw sum
/// against a fixed budget, which is what makes "signal metrics missing" a
/// non-special case: the metadata components' own max simply becomes the
/// whole denominator.
///
/// Blockiness stays a zero-max annotation: ffmpeg's blockdetect scale has
/// no calibrated good/bad reference (clean captures measured 105–115,
/// above the placeholder bad-at of 80 — scoring it would judge every
/// clean file 0). It displays; it never scores. Do not "fix" this without
/// a real calibration.
public enum QualityScore {
    static let losslessAudioCodecs: Set<String> = [
        "flac", "alac", "wav", "wavpack", "ape", "tta", "truehd",
        "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_f32le", "pcm",
    ]
    static let modernLossyAudioCodecs: Set<String> = ["aac", "opus", "vorbis", "ogg"]

    public static func compute(
        for item: MediaItem, analysis: QualityAnalysisMetrics? = nil
    ) -> QualityScoreResult {
        var components: [ScoreComponent] = []

        if item.kind == .audio {
            addAudioComponents(&components, item, analysis, includeBitrate: true)
        } else {
            components.append(videoCodecComponent(item))
            components.append(resolutionComponent(item))
            components.append(videoBitrateComponent(item))

            if hasVideoSignal(analysis) {
                components.append(blockinessComponent(analysis!))
                components.append(blurrinessComponent(analysis!))
            } else {
                components.append(ScoreComponent("Video signal", 0, 0, "signal analysis unavailable"))
            }
            // A muxed file has no separate audio bitrate — skip that
            // component, matching the old composition.
            if (item.audioStreamCount ?? 0) > 0 {
                addAudioComponents(&components, item, analysis, includeBitrate: false)
            }
        }
        return scale(components)
    }

    private static func addAudioComponents(
        _ components: inout [ScoreComponent], _ item: MediaItem,
        _ analysis: QualityAnalysisMetrics?, includeBitrate: Bool
    ) {
        components.append(audioCodecComponent(item))
        components.append(sampleRateComponent(item))
        components.append(bitDepthComponent(item))
        if includeBitrate { components.append(audioBitrateComponent(item)) }

        if hasAudioSignal(analysis) {
            components.append(rolloffComponent(item, analysis!))
            components.append(clippingComponent(analysis!))
        } else {
            components.append(ScoreComponent("Audio signal", 0, 0, "signal analysis unavailable"))
        }
    }

    private static func hasAudioSignal(_ a: QualityAnalysisMetrics?) -> Bool {
        guard let a, !a.analysisFailed else { return false }
        return a.audioRolloffHz != nil || a.audioPeakDb != nil || a.audioRmsDb != nil
    }

    private static func hasVideoSignal(_ a: QualityAnalysisMetrics?) -> Bool {
        guard let a, !a.analysisFailed else { return false }
        return a.videoBlockiness != nil || a.videoBlurriness != nil
    }

    // MARK: - Audio metadata (budgets from the old tier tables)

    private static func audioCodecComponent(_ item: MediaItem) -> ScoreComponent {
        let max = 25.0
        guard let codec = item.audioCodec?.lowercased() else {
            return ScoreComponent("Audio codec", 5, max, "unknown codec")
        }
        if losslessAudioCodecs.contains(codec) {
            return ScoreComponent("Audio codec", 25, max, "\(codec) (lossless)")
        }
        if modernLossyAudioCodecs.contains(codec) {
            return ScoreComponent("Audio codec", 15, max, "\(codec) (modern lossy)")
        }
        return ScoreComponent("Audio codec", 5, max, "\(codec) (legacy/other lossy)")
    }

    private static func sampleRateComponent(_ item: MediaItem) -> ScoreComponent {
        let max = 15.0
        let points: Double = switch item.sampleRate {
        case .some(let sr) where sr >= 44_100: max
        case .some(let sr) where sr >= 32_000: max * 0.6
        case .some(let sr) where sr >= 16_000: max * 0.3
        default: max * 0.1
        }
        let note = item.sampleRate.map { "\($0) Hz" } ?? "sample rate unknown"
        return ScoreComponent("Sample rate", points, max, note)
    }

    private static func bitDepthComponent(_ item: MediaItem) -> ScoreComponent {
        let max = 15.0
        let points: Double = switch item.bitDepth {
        case .some(let bd) where bd >= 24: max
        case .some(16): max * 0.8
        default: max * 0.3
        }
        let note = item.bitDepth.map { "\($0)-bit" } ?? "bit depth unknown"
        return ScoreComponent("Bit depth", points, max, note)
    }

    private static func audioBitrateComponent(_ item: MediaItem) -> ScoreComponent {
        let max = 15.0
        let bitrate = item.bitrate ?? 0
        let points: Double = switch bitrate {
        case let b where b >= 320_000: max
        case let b where b >= 192_000: max * 0.7
        case let b where b >= 128_000: max * 0.4
        default: max * 0.15
        }
        let note = bitrate > 0 ? "\(bitrate / 1000) kbps" : "bitrate unknown"
        return ScoreComponent("Audio bitrate", points, max, note)
    }

    // MARK: - Audio signal

    private static func rolloffComponent(_ item: MediaItem, _ a: QualityAnalysisMetrics) -> ScoreComponent {
        let max = 20.0
        guard let rolloff = a.audioRolloffHz else {
            return ScoreComponent("Rolloff", max * 0.5, max, "rolloff unavailable")
        }
        let nyquist = (item.sampleRate ?? 0) > 0 ? Double(item.sampleRate!) / 2.0 : 22_050
        if rolloff >= nyquist * 0.85 {
            return ScoreComponent(
                "Rolloff", max, max,
                String(format: "%.0f Hz (near-Nyquist, full spectrum present)", rolloff))
        }
        if rolloff < 16_000 {
            let isLossless = item.audioCodec.map { losslessAudioCodecs.contains($0.lowercased()) } ?? false
            let note = isLossless
                ? "high frequencies missing despite lossless codec — likely lossy transcode"
                : String(format: "%.0f Hz — high frequencies missing", rolloff)
            return ScoreComponent("Rolloff", max * 0.1, max, note)
        }
        return ScoreComponent(
            "Rolloff", max * 0.5, max,
            String(format: "%.0f Hz — partial high-frequency loss", rolloff))
    }

    private static func clippingComponent(_ a: QualityAnalysisMetrics) -> ScoreComponent {
        let max = 10.0
        if let peak = a.audioPeakDb, let rms = a.audioRmsDb, peak >= -0.5, rms >= -12 {
            return ScoreComponent("Clipping", 0, max, "peak/RMS pattern indicates clipping")
        }
        return ScoreComponent("Clipping", max, max)
    }

    // MARK: - Video metadata

    private static func videoCodecComponent(_ item: MediaItem) -> ScoreComponent {
        let max = 25.0
        let (points, label): (Double, String) = switch item.videoCodec?.lowercased() {
        case "hevc", "h265": (max, "HEVC")
        case "h264": (max * 0.7, "H.264")
        case .some(let codec): (max * 0.3, "\(codec) (other/legacy)")
        case nil: (max * 0.3, "unknown codec")
        }
        return ScoreComponent("Video codec", points, max, label)
    }

    private static func resolutionComponent(_ item: MediaItem) -> ScoreComponent {
        let max = 20.0
        let width = item.width ?? 0
        let height = item.height ?? 0
        let pixels = Int64(width) * Int64(height)
        let points: Double = switch pixels {
        case let p where p >= 3840 * 2160: max
        case let p where p >= 1920 * 1080: max * 0.8
        case let p where p >= 1280 * 720: max * 0.55
        case let p where p >= 720 * 480: max * 0.3
        default: max * 0.15
        }
        return ScoreComponent("Resolution", points, max, "\(width)x\(height)")
    }

    private static func videoBitrateComponent(_ item: MediaItem) -> ScoreComponent {
        let max = 20.0
        let pixels = Double(item.width ?? 0) * Double(item.height ?? 0)
        let fps = (item.frameRate ?? 0) > 0 ? item.frameRate! : 30.0
        let bitsPerPixel = pixels > 0 ? Double(item.bitrate ?? 0) / (pixels * fps) : 0
        let points: Double = switch bitsPerPixel {
        case let b where b >= 0.12: max
        case let b where b >= 0.06: max * 0.7
        case let b where b >= 0.03: max * 0.4
        default: max * 0.15
        }
        return ScoreComponent("Bitrate", points, max, String(format: "%.3f bits/px", bitsPerPixel))
    }

    // MARK: - Video signal

    private static func blockinessComponent(_ a: QualityAnalysisMetrics) -> ScoreComponent {
        guard let v = a.videoBlockiness else {
            return ScoreComponent("Blockiness", 0, 0, "blockiness unavailable")
        }
        return ScoreComponent(
            "Blockiness", 0, 0, String(format: "blockdetect %.1f — no calibrated scale yet", v))
    }

    private static func blurrinessComponent(_ a: QualityAnalysisMetrics) -> ScoreComponent {
        let max = 10.0
        guard let v = a.videoBlurriness else {
            return ScoreComponent("Blurriness", max * 0.5, max, "blurriness unavailable")
        }
        let points = inverseLinear(v, goodAt: 2, badAt: 10, max: max)
        return ScoreComponent("Blurriness", points, max, String(format: "blurdetect %.1f", v))
    }

    private static func inverseLinear(_ value: Double, goodAt: Double, badAt: Double, max: Double) -> Double {
        if value <= goodAt { return max }
        if value >= badAt { return 0 }
        return max * (badAt - value) / (badAt - goodAt)
    }

    private static func scale(_ components: [ScoreComponent]) -> QualityScoreResult {
        let earned = components.reduce(0) { $0 + $1.points }
        let possible = components.reduce(0) { $0 + $1.maxPoints }
        let total = possible > 0 ? min(100, max(0, earned / possible * 100)) : 0
        return QualityScoreResult(total: (total * 10).rounded() / 10, components: components)
    }
}
