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
    public let version = 1
    public let kinds: Set<MediaKind> = [.video, .audio]
    public let pass = 1

    public init() {}

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

        var findings = meter.findings()
        findings.measure("audio.present", 1)
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
}
