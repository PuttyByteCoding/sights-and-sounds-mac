import AppKit
import AVFoundation
import Foundation
import SightsAndSoundsKit

/// Timeline hover thumbnails via AVAssetImageGenerator — the replacement
/// for the web app's sprite sheets, generated on demand instead of ahead
/// of time. Times are bucketed so a slow hover pass over the scrubber
/// reuses frames instead of generating per-pixel. Actors traffic in JPEG
/// `Data` only (NSImage is not Sendable).
actor ScrubPreviewProvider {
    static let shared = ScrubPreviewProvider()

    /// Seconds per preview bucket — coarse enough to feel instant with
    /// keyframe-tolerant generation.
    static let bucketSeconds: Double = 5

    private let memory = NSCache<NSString, NSData>()
    private var generators: [UUID: AVAssetImageGenerator] = [:]

    init() {
        memory.countLimit = 400
    }

    func preview(itemID: UUID, fileURL: URL, atSeconds seconds: Double) async -> Data? {
        let bucket = Int(seconds / Self.bucketSeconds)
        let key = "\(itemID)/\(bucket)" as NSString
        if let cached = memory.object(forKey: key) { return cached as Data }

        let generator = generators[itemID] ?? {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 320, height: 320)
            // Keyframe-tolerant: fast beats exact for hover previews.
            g.requestedTimeToleranceBefore = CMTime(seconds: Self.bucketSeconds, preferredTimescale: 600)
            g.requestedTimeToleranceAfter = CMTime(seconds: Self.bucketSeconds, preferredTimescale: 600)
            generators[itemID] = g
            return g
        }()

        // The callback API, bridged by a continuation: the generator never
        // leaves the actor (its async `image(at:)` would send it), and the
        // JPEG conversion happens in the callback with only Sendable data
        // crossing back.
        let time = CMTime(seconds: Double(bucket) * Self.bucketSeconds, preferredTimescale: 600)
        let data: Data? = await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, cgImage, _, result, _ in
                guard result == .succeeded, let cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                continuation.resume(
                    returning: rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]))
            }
        }
        guard let data else { return nil }
        memory.setObject(data as NSData, forKey: key)
        return data
    }

    func releaseGenerator(for itemID: UUID) {
        generators[itemID] = nil
    }
}

/// Audio waveforms: streamed PCM decode → coarse peaks → disk cache.
/// Same disk-state discipline as thumbnails: a cached waveform renders
/// offline; a missing one regenerates when the source is back.
actor WaveformProvider {
    static let shared = WaveformProvider()

    /// Stored resolution; rendering re-buckets down from this.
    static let storedBuckets = 1200

    private var inFlight: [UUID: Task<[Float]?, Never>] = [:]

    private let cacheRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SightsAndSounds/Waveforms", isDirectory: true)
    }()

    func peaks(itemID: UUID, libraryID: UUID, fileURL: URL?) async -> [Float]? {
        let diskURL = cacheRoot
            .appendingPathComponent(libraryID.uuidString, isDirectory: true)
            .appendingPathComponent(itemID.uuidString + ".f32")

        if let data = try? Data(contentsOf: diskURL) {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        guard let fileURL else { return nil }
        if let running = inFlight[itemID] { return await running.value }

        let task = Task<[Float]?, Never> {
            guard let coarse = Self.decodePeaks(url: fileURL) else { return nil }
            let stored = WaveformMath.peaks(samples: coarse, bucketCount: Self.storedBuckets)
            try? FileManager.default.createDirectory(
                at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            stored.withUnsafeBufferPointer { buffer in
                try? Data(buffer: buffer).write(to: diskURL)
            }
            return stored
        }
        inFlight[itemID] = task
        let result = await task.value
        inFlight[itemID] = nil
        return result
    }

    /// Streamed decode: mono Float32 PCM, one peak per 4096-sample block,
    /// so an hours-long recording never holds full samples in memory.
    private static func decodePeaks(url: URL) -> [Float]? {
        let asset = AVURLAsset(url: url)
        // Synchronous track load inside the actor task: acceptable for a
        // background decode; AVAssetReader itself is synchronous anyway.
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nil }

        var blockPeaks: [Float] = []
        let blockSize = 4096
        var currentPeak: Float = 0
        var currentCount = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bytes)
            bytes.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Float.self) {
                    currentPeak = max(currentPeak, abs(sample))
                    currentCount += 1
                    if currentCount == blockSize {
                        blockPeaks.append(currentPeak)
                        currentPeak = 0
                        currentCount = 0
                    }
                }
            }
        }
        if currentCount > 0 { blockPeaks.append(currentPeak) }
        return reader.status == .completed ? blockPeaks : nil
    }
}
