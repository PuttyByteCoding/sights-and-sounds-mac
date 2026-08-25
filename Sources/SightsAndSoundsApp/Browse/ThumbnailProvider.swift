import AppKit
import AVFoundation
import Foundation

/// On-demand grid thumbnails via AVAssetImageGenerator, cached to disk.
///
/// The cache is what keeps an offline source *looking* complete: once a
/// thumbnail has been generated it renders from disk whether or not the
/// file is reachable. Missing thumbnails self-heal on the next request
/// with the source online — disk state decides, no flags (the worker in
/// Phase 5 follows the same rule).
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private let cacheRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SightsAndSounds/Thumbnails", isDirectory: true)
    }()

    /// The cached thumbnail, generating it if needed and possible.
    /// `fileURL` nil (offline source) still serves from cache.
    func thumbnail(itemID: UUID, libraryID: UUID, fileURL: URL?, durationSeconds: Double?) async -> NSImage? {
        let key = "\(libraryID)/\(itemID)"
        if let cached = memory.object(forKey: key as NSString) { return cached }

        if let existing = inFlight[key] { return await existing.value }
        let task = Task<NSImage?, Never> { [cacheRoot] in
            let diskURL = cacheRoot
                .appendingPathComponent(libraryID.uuidString, isDirectory: true)
                .appendingPathComponent(itemID.uuidString + ".jpg")

            if let image = NSImage(contentsOf: diskURL) { return image }
            guard let fileURL else { return nil }

            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            // A representative frame: a quarter in, capped at one minute.
            let seconds = min((durationSeconds ?? 8) * 0.25, 60)
            guard let cgImage = try? await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            else { return nil }

            try? FileManager.default.createDirectory(
                at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpeg.write(to: diskURL)
            }
            return NSImage(cgImage: cgImage, size: .zero)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }
}
