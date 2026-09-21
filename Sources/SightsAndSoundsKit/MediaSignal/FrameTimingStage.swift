import AVFoundation
import CoreMedia
import Foundation

/// Walks the video track's frame table and measures its timing.
///
/// A sample cursor reads the table the container already holds (times,
/// sizes, sync flags) without reading a byte of picture data, so a two-hour
/// file on a network share costs about what a short one does. Containers
/// that cannot offer a cursor are read sample by sample instead, which
/// gives the same numbers and reads the whole file to get them.
public struct FrameTimingStage: SignalStage {
    public let name = "frameTiming"
    public let version = 1
    public let kinds: Set<MediaKind> = [.video]

    public init() {}

    public func examine(_ file: SignalStageInput) async throws -> SignalFindings {
        let asset = AVURLAsset(url: file.url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw SignalStageError("no video track AVFoundation can read")
        }
        let dimensions = (try? await track.load(.formatDescriptions))?.first?.dimensions

        let samples: [FrameSample]
        var firstSample: Data?
        let offersCursors = (try? await track.load(.canProvideSampleCursors)) ?? false
        if offersCursors, let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() {
            firstSample = Self.sampleData(at: cursor, in: file.url)
            samples = try await Self.walk(cursor, file: file)
        } else {
            (samples, firstSample) = try await Self.read(track, of: asset, file: file)
        }
        guard samples.count >= 2 else {
            throw SignalStageError("the video track has fewer than two frames")
        }

        var findings = FrameTiming.measure(
            samples,
            encodedWidth: dimensions.map { Int($0.width) },
            encodedHeight: dimensions.map { Int($0.height) })
        // Declared, not measured: it is the encoder's own account of what
        // it did, and the only certain proof in the file of a transcode.
        findings.declare(
            "video.encoderSettings",
            firstSample.flatMap(CodecConfiguration.encoderSettings(inFirstSample:)))
        return findings
    }

    private static func walk(_ cursor: AVSampleCursor, file: SignalStageInput) async throws -> [FrameSample] {
        var samples: [FrameSample] = []
        repeat {
            if samples.count.isMultiple(of: 20_000) { try await file.checkCancellation() }
            let shown = cursor.presentationTimeStamp.seconds
            let decoded = cursor.decodeTimeStamp.seconds
            guard shown.isFinite else { continue }
            samples.append(FrameSample(
                presentationSeconds: shown,
                decodeSeconds: decoded.isFinite ? decoded : shown,
                byteCount: Int(cursor.currentSampleStorageRange.length),
                isKeyframe: cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue))
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        return samples
    }

    /// The first frame's bytes, which is where an encoder leaves its
    /// settings. Capped: a settings string is a few hundred bytes at the
    /// front of the sample, and the first frame of a 4K file is not small.
    private static func sampleData(at cursor: AVSampleCursor, in url: URL) -> Data? {
        let range = cursor.currentSampleStorageRange
        guard range.length > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(range.offset))
        return try? handle.read(upToCount: min(Int(range.length), 65_536))
    }

    private static func read(
        _ track: AVAssetTrack, of asset: AVAsset, file: SignalStageInput
    ) async throws -> (samples: [FrameSample], first: Data?) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw SignalStageError("cannot read frames: \(reader.error?.localizedDescription ?? "unknown")")
        }
        var samples: [FrameSample] = []
        var first: Data?
        while let buffer = output.copyNextSampleBuffer() {
            if samples.count.isMultiple(of: 2_000), await file.isCancelled() {
                reader.cancelReading()
                throw CancellationError()
            }
            let shown = buffer.presentationTimeStamp.seconds
            guard shown.isFinite, buffer.numSamples > 0 else { continue }
            if first == nil { first = try? buffer.dataBuffer?.dataBytes().prefix(65_536) }
            let decoded = buffer.decodeTimeStamp.seconds
            let attachments = buffer.sampleAttachments.first
            let notSync = attachments?[.notSync] as? Bool ?? false
            samples.append(FrameSample(
                presentationSeconds: shown,
                decodeSeconds: decoded.isFinite ? decoded : shown,
                byteCount: buffer.totalSampleSize,
                isKeyframe: !notSync))
        }
        return (samples, first)
    }
}
