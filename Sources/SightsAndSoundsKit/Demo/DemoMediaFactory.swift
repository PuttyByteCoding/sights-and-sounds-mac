import AVFoundation
import CoreText
import CoreVideo
import Foundation

/// Synthesizes tiny real media files so demo libraries exercise the whole
/// pipeline — thumbnails, scrub previews, waveforms, playback — with zero
/// real data. Video: a few seconds of drifting color bars (H.264). Audio:
/// a chord of sine waves (AAC).
///
/// Video synthesis is async and **serialized through a gate**: concurrent
/// AVAssetWriter H.264 sessions starve the small software encoder on CI
/// virtual machines, and blocking waits starve the cooperative thread
/// pool — the combination hung CI for over an hour. One session at a
/// time, suspending (never blocking) between frames, every wait bounded.
public enum DemoMediaFactory {
    public struct GenerationError: Error, CustomStringConvertible {
        public let stage: String
        public var description: String { "demo media generation failed at \(stage)" }
    }

    /// Write a small MP4. `variant` shifts the palette so files are
    /// visually distinct in the grid.
    public static func writeVideo(
        to url: URL, seconds: Double = 4, variant: Int = 0, overlayText: String? = nil
    ) async throws {
        try await SerialGate.shared.withTurn {
            try await writeVideoUnserialized(
                to: url, seconds: seconds, variant: variant, overlayText: overlayText)
        }
    }

    private static func writeVideoUnserialized(
        to url: URL, seconds: Double, variant: Int, overlayText: String?
    ) async throws {
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
            // Bounded, suspending wait — a stalled encoder fails the write
            // instead of hanging the process.
            var waited = 0
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
                waited += 1
                if waited > 1_000 { throw GenerationError(stage: "encoder stalled") }
            }
            guard let pool = adaptor.pixelBufferPool else { throw GenerationError(stage: "bufferPool") }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw GenerationError(stage: "pixelBuffer") }

            fill(pixelBuffer, frame: frame, variant: variant, width: width, height: height)
            if let overlayText {
                drawText(overlayText, into: pixelBuffer, width: width, height: height)
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }

        input.markAsFinished()
        await writer.finishWriting()
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

    /// Burn text into a BGRA pixel buffer via CoreGraphics — big, white,
    /// black-boxed: material Vision can actually read at 320x180.
    private static func drawText(_ text: String, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil),
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let x = (CGFloat(width) - bounds.width) / 2
        let y = (CGFloat(height) - bounds.height) / 2

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(
            x: x - 10, y: y - 10, width: bounds.width + 20, height: bounds.height + 20))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }

    /// Write a small M4A: a three-note chord with a slow amplitude swell,
    /// pitched by variant. Pure CPU (no encoder session, no callbacks) —
    /// safe to stay synchronous.
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

/// FIFO turn-taking for async work: unlike a bare actor (whose suspension
/// points interleave), each turn fully completes before the next starts.
actor SerialGate {
    static let shared = SerialGate()

    private var tail: Task<Void, Never> = Task {}

    func withTurn<T: Sendable>(_ op: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let turn = Task { () throws -> T in
            await previous.value
            return try await op()
        }
        tail = Task { _ = try? await turn.value }
        return try await turn.value
    }
}
