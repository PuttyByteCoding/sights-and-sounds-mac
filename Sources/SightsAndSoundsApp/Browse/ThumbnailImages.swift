import AppKit
import ImageIO

/// Decoded thumbnails, at the size they are drawn.
///
/// `ThumbnailProvider` hands out JPEG bytes (an `NSImage` cannot cross
/// its actor). Each tile then built an `NSImage` from those bytes every
/// time it came back on screen — the stored 640 px frame, whatever size
/// the tile was, decoded on the main thread when first drawn. This
/// decodes off the main thread, down to the size asked for, once, and
/// keeps the result.
@MainActor
final class ThumbnailImages {
    static let shared = ThumbnailImages()

    private let cache = NSCache<NSString, NSImage>()

    init() {
        // Decoded pixels: about 300 MB, which is a few thousand tiles at
        // an ordinary size.
        cache.totalCostLimit = 300 * 1024 * 1024
    }

    /// Sizes are rounded up to the next 50 px, so dragging the size
    /// slider decodes a handful of sizes rather than one per point.
    static func bucket(_ maxPixel: CGFloat) -> Int {
        max(50, Int((maxPixel / 50).rounded(.up)) * 50)
    }

    private func cacheKey(_ key: String, _ maxPixel: CGFloat) -> NSString {
        "\(key)@\(Self.bucket(maxPixel))" as NSString
    }

    func cached(key: String, maxPixel: CGFloat) -> NSImage? {
        cache.object(forKey: cacheKey(key, maxPixel))
    }

    /// The image for these bytes, no larger than `maxPixel` on its long
    /// side, and never enlarged.
    func image(key: String, data: Data, maxPixel: CGFloat) async -> NSImage? {
        let name = cacheKey(key, maxPixel)
        if let hit = cache.object(forKey: name) { return hit }
        let limit = Self.bucket(maxPixel)
        guard let decoded = await Task.detached(priority: .userInitiated, operation: {
            Self.downsample(data, maxPixel: limit)
        }).value else { return nil }
        // Another request for the same tile may have landed meanwhile.
        if let hit = cache.object(forKey: name) { return hit }
        let cgImage = decoded.image
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: name, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// What a tile asks for: the image for a thumbnail drawn `points`
    /// wide, on this screen. nil points means "as stored" — for surfaces
    /// whose size is not known where they load.
    func image(libraryID: UUID, itemID: UUID, data: Data?, points: CGFloat?) async -> NSImage? {
        guard let data else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return await image(
            key: "\(libraryID)/\(itemID)", data: data,
            maxPixel: points.map { $0 * scale } ?? 640)
    }

    /// `CGImage` is immutable; the wrapper is only so it can leave the
    /// detached task under every SDK this builds with.
    private struct Decoded: @unchecked Sendable { let image: CGImage }

    private nonisolated static func downsample(_ data: Data, maxPixel: Int) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode NOW, on this thread, not lazily at first draw.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Decoded.init)
    }
}
