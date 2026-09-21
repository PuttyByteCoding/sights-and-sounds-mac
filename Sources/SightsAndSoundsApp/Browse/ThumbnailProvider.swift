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
///
/// What it is careful about, because a grid asks once per tile as tiles
/// scroll past:
///   - where the item's file is gets worked out only when a thumbnail has
///     to be rendered, and then off the main actor. It is database reads
///     and a reachability check; tiles used to pay for it on the main
///     thread before the cache was even consulted;
///   - only a few renders run at once, newest request first, so the tiles
///     on screen are not queued behind everything a fast scroll passed;
///   - a request nobody is waiting for any more is dropped when its turn
///     comes instead of rendered.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    /// Renders one frame of the file as JPEG bytes. Replaceable in tests.
    typealias Renderer = @Sendable (_ file: URL, _ durationSeconds: Double?) async -> Data?

    private let memory = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var waiting: [String: Int] = [:]
    private let render: Renderer

    private let maxConcurrent: Int
    private var rendering = 0
    private var turnQueue: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 3, render: @escaping Renderer = ThumbnailProvider.renderFrame) {
        self.maxConcurrent = maxConcurrent
        self.render = render
        // JPEG bytes, not decoded images: about 250 MB is several thousand.
        memory.totalCostLimit = 250 * 1024 * 1024
    }

    /// Cached JPEG bytes, generating them if needed and possible.
    /// `resolveFile` is only called when a thumbnail has to be rendered,
    /// never on the caller's actor; nil from it (an offline source) means
    /// there is nothing to render from.
    func thumbnailData(
        itemID: UUID, libraryID: UUID, durationSeconds: Double?,
        resolveFile: @escaping @Sendable () -> URL?
    ) async -> Data? {
        let key = "\(libraryID)/\(itemID)"
        if let cached = memory.object(forKey: key as NSString) { return cached as Data }

        waiting[key, default: 0] += 1
        let task = inFlight[key] ?? startLoad(
            key: key, itemID: itemID, libraryID: libraryID,
            durationSeconds: durationSeconds, resolveFile: resolveFile)
        // `Task.value` does not return early when the caller is cancelled,
        // so the tile going away is heard through the handler instead.
        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.stoppedWaiting(for: key) }
        }
        if !Task.isCancelled { stoppedWaiting(for: key) }
        return data
    }

    private func stoppedWaiting(for key: String) {
        guard let count = waiting[key] else { return }
        waiting[key] = count > 1 ? count - 1 : nil
    }

    private func startLoad(
        key: String, itemID: UUID, libraryID: UUID, durationSeconds: Double?,
        resolveFile: @escaping @Sendable () -> URL?
    ) -> Task<Data?, Never> {
        let render = render
        let task = Task<Data?, Never> {
            let diskURL = ThumbnailStore.url(libraryID: libraryID, itemID: itemID)
            if let data = await Self.offActor({ try? Data(contentsOf: diskURL) }) { return data }

            await self.takeTurn()
            defer { self.finishTurn() }
            // The tile scrolled away while this waited: render nothing.
            guard self.waiting[key] != nil else { return nil }

            guard let fileURL = await Self.offActor(resolveFile) else { return nil }
            guard let jpeg = await render(fileURL, durationSeconds) else { return nil }
            await Self.offActor {
                try? FileManager.default.createDirectory(
                    at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg.write(to: diskURL)
            }
            return jpeg
        }
        inFlight[key] = task
        Task {
            let data = await task.value
            self.loadFinished(key: key, data: data)
        }
        return task
    }

    private func loadFinished(key: String, data: Data?) {
        inFlight[key] = nil
        if let data { memory.setObject(data as NSData, forKey: key as NSString, cost: data.count) }
    }

    // MARK: - Turns

    /// Wait for one of the render slots. Newest first: what was asked for
    /// last is what is on screen now.
    private func takeTurn() async {
        if rendering < maxConcurrent {
            rendering += 1
            return
        }
        await withCheckedContinuation { turnQueue.append($0) }
    }

    private func finishTurn() {
        if let next = turnQueue.popLast() {
            next.resume()  // the slot passes straight to it
        } else {
            rendering -= 1
        }
    }

    // MARK: - Work that must not run on this actor

    /// File reads, the file lookup and the JPEG write each block; on the
    /// actor they would run one at a time, in arrival order, for the
    /// whole grid.
    private static func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility) { work() }.value
    }

    static let renderFrame: Renderer = { fileURL, durationSeconds in
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        // A representative frame: a quarter in, capped at one minute.
        let seconds = min((durationSeconds ?? 8) * 0.25, 60)
        guard let cgImage = try? await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
