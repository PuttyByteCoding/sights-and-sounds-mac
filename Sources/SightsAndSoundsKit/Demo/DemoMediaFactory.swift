import AVFoundation
import CoreVideo
import Foundation

/// Synthesizes tiny real media files so demo libraries exercise the whole
/// pipeline — thumbnails, scrub previews, waveforms, playback — with zero
/// real data. Video: a few seconds of drifting color bars (H.264). Audio:
/// a chord of sine waves (AAC).
public enum DemoMediaFactory {
    public struct GenerationError: Error, CustomStringConvertible {
        public let stage: String
        public var description: String { "demo media generation failed at \(stage)" }
    }

    /// Write a small MP4. `variant` shifts the palette so files are
    /// visually distinct in the grid. Synchronous by design — the demo
    /// flow runs it on a background task and the seeder's per-file
    /// callback stays a plain closure.
    public static func writeVideo(
        to url: URL, seconds: Double = 4, variant: Int = 0
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let width = 320, height = 180, fps = 12
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw GenerationError(stage: "startWriting") }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(seconds * Double(fps))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                usleep(2000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw GenerationError(stage: "bufferPool") }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw GenerationError(stage: "pixelBuffer") }

            fill(pixelBuffer, frame: frame, variant: variant, width: width, height: height)
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw GenerationError(stage: "finish: \(writer.error.map(String.init(describing:)) ?? "unknown")")
        }
    }

    /// Vertical color bars drifting sideways, hue keyed to the variant.
    private static func fill(_ buffer: CVPixelBuffer, frame: Int, variant: Int, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let bar = ((x + frame * 4) / 40 + variant) % 6
                let shade = UInt8(120 + 20 * ((y / 30) % 4))
                let offset = y * bytesPerRow + x * 4
                let (b, g, r): (UInt8, UInt8, UInt8) = switch bar {
                case 0: (shade, 40, 40)
                case 1: (40, shade, 40)
                case 2: (40, 40, shade)
                case 3: (shade, shade, 40)
                case 4: (40, shade, shade)
                default: (shade, 40, shade)
                }
                pixels[offset] = b
                pixels[offset + 1] = g
                pixels[offset + 2] = r
                pixels[offset + 3] = 255
            }
        }
    }

    /// Write a small M4A: a three-note chord with a slow amplitude swell,
    /// pitched by variant — waveforms come out visibly different.
    public static func writeAudio(
        to url: URL, seconds: Double = 5, variant: Int = 0
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])

        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = pcmBuffer.floatChannelData?[0]
        else { throw GenerationError(stage: "pcmBuffer") }

        let root = 196.0 * pow(1.122, Double(variant % 8))  // walk up a scale
        for index in 0..<Int(frameCount) {
            let t = Double(index) / sampleRate
            let swell = 0.4 + 0.35 * sin(t * 0.9)
            let value = sin(2 * .pi * root * t)
                + 0.6 * sin(2 * .pi * root * 1.5 * t)
                + 0.4 * sin(2 * .pi * root * 2.0 * t)
            samples[index] = Float(value / 2.0 * swell * 0.5)
        }
        pcmBuffer.frameLength = frameCount
        try file.write(from: pcmBuffer)
    }
}
