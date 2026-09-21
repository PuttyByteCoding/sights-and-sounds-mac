import AVFoundation
import CoreMedia
import Foundation
import Vision

/// Why a frame was passed over when choosing stills to measure.
public enum FrameRejection: String, Sendable {
    /// Nothing to measure in a black frame, and it bounds no border.
    case black
    /// A flat card or a fade's midpoint: no detail, no noise, no edges.
    case flat
    /// Titles and credits are graphics laid over (or instead of) the
    /// picture, usually at a different quality from it.
    case text
}

public enum FrameTriage {
    public static func rejection(of frame: PictureFrame) -> FrameRejection? {
        let (mean, deviation) = frame.lumaMeanAndDeviation()
        if mean < 28 { return .black }
        if deviation < 5 { return .flat }
        return nil
    }

    /// The share of the frame covered by detected text.
    static func textCoverage(of buffer: CVPixelBuffer) -> Double {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([request])) != nil else { return 0 }
        return (request.results ?? []).reduce(0) {
            $0 + Double($1.boundingBox.width * $1.boundingBox.height)
        }
    }
}

/// Decodes the frames the picture stages measure.
///
/// Stills are taken at sixteen points from 5 % to 95 % of the running
/// time. A point that lands on black, a flat card or a screen of text
/// steps forward a little over a second at a time, a few times, looking
/// for picture; what was passed over is counted, because a file that is
/// mostly titles is worth knowing about.
public enum FrameSampler {
    public static let stillFractions: [Double] = (0..<16).map { 0.05 + Double($0) * 0.06 }
    static let retryStepSeconds = 1.2
    static let retries = 4
    static let textCoverageLimit = 0.10

    public struct Stills: Sendable {
        public var frames: [PictureFrame] = []
        public var rejected: [FrameRejection: Int] = [:]
        public var pixelAspectRatio: Double = 1
        public var durationSeconds: Double = 0
    }

    public static func stills(
        of url: URL, fractions: [Double] = stillFractions,
        isCancelled: @Sendable () async -> Bool = { false }
    ) async throws -> Stills {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw SignalStageError("no video track AVFoundation can read")
        }
        let duration = ((try? await asset.load(.duration))?.seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        guard duration > 0 else { throw SignalStageError("the file reports no duration") }
        let description = (try? await track.load(.formatDescriptions))?.first

        var stills = Stills()
        stills.durationSeconds = duration
        stills.pixelAspectRatio = description.map(pixelAspectRatio) ?? 1
        let format = pixelFormat(for: description)

        var fallbacks: [PictureFrame] = []
        for fraction in fractions {
            if await isCancelled() { throw CancellationError() }
            let start = duration * fraction
            let outcome = try still(
                from: asset, track: track, at: start, format: format,
                until: min(start + retryStepSeconds * Double(retries) + 1, duration))
            for rejection in outcome.rejections { stills.rejected[rejection, default: 0] += 1 }
            if let frame = outcome.frame {
                stills.frames.append(frame)
            } else if let fallback = outcome.fallback {
                fallbacks.append(fallback)
            }
        }
        // A file that is dark or flat throughout still has to be measured
        // with something; black frames alone are never used.
        if stills.frames.count < 6 { stills.frames += fallbacks }
        stills.frames.sort { $0.positionSeconds < $1.positionSeconds }
        return stills
    }

    private static func still(
        from asset: AVAsset, track: AVAssetTrack, at start: Double, format: OSType, until end: Double
    ) throws -> (frame: PictureFrame?, fallback: PictureFrame?, rejections: [FrameRejection]) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: max(end - start, 0.5), preferredTimescale: 600))
        guard reader.startReading() else {
            throw SignalStageError("cannot decode frames: \(reader.error?.localizedDescription ?? "unknown")")
        }
        defer { reader.cancelReading() }

        var rejections: [FrameRejection] = []
        var fallback: PictureFrame?
        var nextCandidate = start
        while rejections.count <= retries, let buffer = output.copyNextSampleBuffer() {
            let shown = buffer.presentationTimeStamp.seconds
            guard shown.isFinite, shown >= nextCandidate - 0.001, let pixels = buffer.imageBuffer,
                  let frame = PictureFrame(pixels, positionSeconds: shown)
            else { continue }
            var rejection = FrameTriage.rejection(of: frame)
            if rejection == nil, FrameTriage.textCoverage(of: pixels) > textCoverageLimit {
                rejection = .text
            }
            guard let rejection else { return (frame, nil, rejections) }
            rejections.append(rejection)
            if rejection != .black, fallback == nil { fallback = frame }
            nextCandidate = shown + retryStepSeconds
        }
        return (nil, fallback, rejections)
    }

    /// Ask for the decoded depth the file was encoded at. A 10-bit file
    /// decoded to 8 bits has lost the two bits whose use is being measured.
    static func pixelFormat(for description: CMFormatDescription?) -> OSType {
        guard let description else { return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
        let extensions = (CMFormatDescriptionGetExtensions(description) as? [String: Any]) ?? [:]
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
            as? [String: Any]
        let depth = ((atoms?["avcC"] as? Data).flatMap(CodecConfiguration.avc)
            ?? (atoms?["hvcC"] as? Data).flatMap(CodecConfiguration.hevc))?.bitDepth
            ?? (extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue
            ?? 8
        let fullRange = (extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? NSNumber)?
            .boolValue ?? false
        switch (depth > 8, fullRange) {
        case (false, false): return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case (false, true): return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case (true, false): return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (true, true): return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        }
    }

    static func pixelAspectRatio(_ description: CMFormatDescription) -> Double {
        let extensions = (CMFormatDescriptionGetExtensions(description) as? [String: Any]) ?? [:]
        guard let aspect = extensions[kCMFormatDescriptionExtension_PixelAspectRatio as String] as? [String: Any],
              let horizontal = (aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber)?.doubleValue,
              let vertical = (aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber)?.doubleValue,
              horizontal > 0, vertical > 0
        else { return 1 }
        return horizontal / vertical
    }

    // MARK: - Sequences

    /// Where the decoded windows start, as fractions of the running time.
    public static let windowFractions = [0.2, 0.4, 0.6, 0.8]
    static let windowSeconds = 10.0

    /// The windows to decode for a file of this length: four of ten
    /// seconds, or for a short file one window of as much as there is.
    public static func windows(durationSeconds: Double) -> [(start: Double, seconds: Double)] {
        guard durationSeconds > 0 else { return [] }
        if durationSeconds < windowSeconds * 6 {
            let length = min(durationSeconds * 0.8, windowSeconds * 2)
            return [(durationSeconds * 0.1, length)]
        }
        return windowFractions.map { (durationSeconds * $0, windowSeconds) }
    }

    /// Decode every frame from `start` for `seconds`, in order, handing
    /// each to `each` as luma cropped to `area`. Returns the frame count.
    @discardableResult
    public static func sequence(
        of url: URL, from start: Double, seconds: Double, area: PictureGeometry.ActiveArea? = nil,
        isCancelled: @Sendable () async -> Bool = { false },
        each: (PictureFrame) -> Void
    ) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw SignalStageError("no video track AVFoundation can read")
        }
        let description = (try? await track.load(.formatDescriptions))?.first
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat(for: description)])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: seconds, preferredTimescale: 600))
        guard reader.startReading() else {
            throw SignalStageError("cannot decode frames: \(reader.error?.localizedDescription ?? "unknown")")
        }
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            if count.isMultiple(of: 60), await isCancelled() {
                reader.cancelReading()
                throw CancellationError()
            }
            let shown = buffer.presentationTimeStamp.seconds
            guard shown.isFinite, let pixels = buffer.imageBuffer,
                  let frame = PictureFrame(pixels, positionSeconds: shown, lumaOnly: true)
            else { continue }
            each(frame.working(in: area))
            count += 1
        }
        return count
    }
}
