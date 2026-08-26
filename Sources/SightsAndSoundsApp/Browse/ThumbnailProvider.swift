import AppKit
import AVFoundation
import Foundation
import SightsAndSoundsKit

/// On-demand grid thumbnails via AVAssetImageGenerator, cached to disk.
///
/// The cache is what keeps an offline source *looking* complete: once a
/// thumbnail has been generated it renders from disk whether or not the
/// file is reachable. Missing thumbnails self-heal on the next request
/// with the source online — disk state decides, no flags (the worker in
/// Phase 5 follows the same rule).
///
/// The actor traffics in JPEG `Data`, not images: `NSImage` is expressly
/// not Sendable, so it never crosses the actor boundary — callers decode
/// on their own side.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let memory = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data?, Never>] = [:]


    /// Cached JPEG bytes, generating them if needed and possible.
    /// `fileURL` nil (offline source) still serves from cache.
    func thumbnailData(itemID: UUID, libraryID: UUID, fileURL: URL?, durationSeconds: Double?) async -> Data? {
        let key = "\(libraryID)/\(itemID)"
        if let cached = memory.object(forKey: key as NSString) { return cached as Data }

        if let existing = inFlight[key] { return await existing.value }
        let task = Task<Data?, Never> {
            let diskURL = ThumbnailStore.url(libraryID: libraryID, itemID: itemID)

            if let data = try? Data(contentsOf: diskURL) { return data }
            guard let fileURL else { return nil }

            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            // A representative frame: a quarter in, capped at one minute.
            let seconds = min((durationSeconds ?? 8) * 0.25, 60)
            guard let cgImage = try? await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            else { return nil }

            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            else { return nil }
            try? FileManager.default.createDirectory(
                at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? jpeg.write(to: diskURL)
            return jpeg
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if let data { memory.setObject(data as NSData, forKey: key as NSString) }
        return data
    }
}
