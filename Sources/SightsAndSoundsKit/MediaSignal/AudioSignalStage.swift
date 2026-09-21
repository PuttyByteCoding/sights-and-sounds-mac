import AVFoundation
import Accelerate
import CoreMedia
import Foundation

/// Decodes the whole of the first sound track and measures it.
///
/// Audio decodes at hundreds of times real time, so there is no sampling
/// here: every second is heard. More than two channels are folded to two
/// by the decoder, which is what the level and spectrum readings want; a
/// mono track stays mono, because turning it into two identical channels
/// would make every mono file look like mono passed off as stereo.
public struct AudioSignalStage: SignalStage {
    public let name = "audioSignal"
    public let version = 2
    public let kinds: Set<MediaKind> = [.video, .audio]
    public let pass = 1

    /// Tracks longer than this are heard in windows, not whole.
    let wholeTrackLimit: Double
    let windowCount: Int
    let windowSeconds: Double

    public init(wholeTrackLimit: Double = 600, windowCount: Int = 12, windowSeconds: Double = 30) {
        self.wholeTrackLimit = wholeTrackLimit
        self.windowCount = windowCount
        self.windowSeconds = windowSeconds
    }

    /// The stretches of a long track that are heard, or nil to hear it all.
    ///
    /// A container interleaves sound with picture, so reading the whole
    /// sound track of a two-hour film means thousands of small reads spread
    /// across the whole file. On local flash that is nothing; on a network
    /// share or a spinning disk it is the slowest thing the sweep does.
    /// What the track is evidence of (its bandwidth, its hiss, a line
    /// whistle, mains hum, whether its channels are one) is as plain in six
    /// minutes spread across the running time as in all of it. Loudness
    /// from windows is an estimate, and `audio.sampled` says so.
    func windows(durationSeconds: Double) -> [(start: Double, seconds: Double)]? {
        guard durationSeconds > wholeTrackLimit, windowCount > 0,
              durationSeconds > Double(windowCount) * windowSeconds
        else { return nil }
        return (0..<windowCount).map { index in
            // Centres at 1/2n, 3/2n, ... of the running time.
            let centre = durationSeconds * (Double(index) + 0.5) / Double(windowCount)
            return (centre - windowSeconds / 2, windowSeconds)
        }
    }

    public func examine(_ file: SignalStageInput) async throws -> SignalFindings {
        let asset = AVURLAsset(url: file.url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            // A silent film is not a failure.
            var findings = SignalFindings()
            findings.measure("audio.present", 0)
            return findings
        }
        guard let format = (try? await track.load(.formatDescriptions))?.first?.audioStreamBasicDescription,
              format.mSampleRate > 0
        else { throw SignalStageError("the sound track does not describe its format") }
        let channels = format.mChannelsPerFrame == 1 ? 1 : 2
        guard let meter = AudioSignalMeter(sampleRate: format.mSampleRate, channels: channels) else {
            throw SignalStageError("unsupported sample rate \(format.mSampleRate)")
        }

        let duration = ((try? await asset.load(.duration))?.seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        let windows = windows(durationSeconds: duration)
        var ranges: [CMTimeRange?] = [nil]
        if let windows {
            ranges = windows.map { window -> CMTimeRange? in
                let start = CMTime(seconds: window.start, preferredTimescale: 48_000)
                let length = CMTime(seconds: window.seconds, preferredTimescale: 48_000)
                return CMTimeRange(start: start, duration: length)
            }
        }
        for range in ranges {
            try await Self.hear(track, of: asset, in: range, channels: channels, into: meter, file: file)
        }

        var findings = meter.findings()
        findings.measure("audio.present", 1)
        findings.measure("audio.sampled", windows == nil ? 0 : 1)
        // Where the sound starts relative to the picture, as the container
        // has it. A track that starts late was usually cut that way, not recorded that way.
        if let video = try? await asset.loadTracks(withMediaType: .video).first,
           let videoRange = try? await video.load(.timeRange),
           let audioRange = try? await track.load(.timeRange) {
            findings.measure("audio.startOffsetSeconds", (audioRange.start - videoRange.start).seconds)
            findings.measure("audio.durationDifferenceSeconds", (audioRange.duration - videoRange.duration).seconds)
        }
        return findings
    }

    /// Decode `range` of the track (all of it when nil) into the meter.
    private static func hear(
        _ track: AVAssetTrack, of asset: AVAsset, in range: CMTimeRange?, channels: Int,
        into meter: AudioSignalMeter, file: SignalStageInput
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: channels,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        if let range { reader.timeRange = range }
        guard reader.startReading() else {
            throw SignalStageError("cannot decode the sound track: \(reader.error?.localizedDescription ?? "unknown")")
        }

        var buffers = 0
        var more = true
        while more {
            buffers += 1
            if buffers.isMultiple(of: 500), await file.isCancelled() {
                reader.cancelReading()
                throw CancellationError()
            }
            // A pool per buffer: see FrameSampler.sequence.
            more = autoreleasepool {
                guard let buffer = output.copyNextSampleBuffer() else { return false }
                guard let data = try? buffer.dataBuffer?.dataBytes() else { return true }
                let interleaved = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                if channels == 1 {
                    meter.consume(left: interleaved, right: nil)
                    return true
                }
                let count = interleaved.count / 2
                var left = [Float](repeating: 0, count: count), right = left
                var unity: Float = 1
                interleaved.withUnsafeBufferPointer { source in
                    // A strided multiply by one is vDSP's strided copy.
                    vDSP_vsmul(source.baseAddress!, 2, &unity, &left, 1, vDSP_Length(count))
                    vDSP_vsmul(source.baseAddress! + 1, 2, &unity, &right, 1, vDSP_Length(count))
                }
                meter.consume(left: left, right: right)
                return true
            }
        }
        if reader.status == .failed {
            throw SignalStageError("the sound track stopped decoding: \(reader.error?.localizedDescription ?? "unknown")")
        }
    }
}
