import AppKit
import Foundation
import Testing

@testable import SightsAndSoundsApp

/// A tile used to rebuild an `NSImage` from its JPEG bytes every time it
/// came back on screen, at the stored 640 px whatever size it was drawn,
/// with the decode happening on the main thread at draw time.
@Suite @MainActor struct ThumbnailImagesTests {

    /// A solid JPEG of the given pixel size.
    private func jpeg(_ width: Int, _ height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .jpeg, properties: [:]))
    }

    private func pixels(_ image: NSImage) -> (Int, Int) {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return (cg?.width ?? 0, cg?.height ?? 0)
    }

    @Test func aThumbnailIsDecodedAtTheSizeItIsDrawn() async throws {
        let cache = ThumbnailImages()
        let data = try jpeg(640, 360)

        let small = try #require(await cache.image(key: "lib/a", data: data, maxPixel: 200))
        #expect(pixels(small) == (200, 113) || pixels(small) == (200, 112))

        // Never enlarged: a source smaller than the tile stays as it is.
        let tiny = try #require(await cache.image(key: "lib/b", data: try jpeg(100, 50), maxPixel: 400))
        #expect(pixels(tiny) == (100, 50))
    }

    @Test func theSameTileAtTheSameSizeIsDecodedOnce() async throws {
        let cache = ThumbnailImages()
        let data = try jpeg(640, 360)

        let first = try #require(await cache.image(key: "lib/a", data: data, maxPixel: 200))
        let again = try #require(await cache.image(key: "lib/a", data: data, maxPixel: 200))
        #expect(first === again)
        #expect(cache.cached(key: "lib/a", maxPixel: 200) === first)

        // A different size is a different image; nearby sizes share one,
        // so dragging the size slider does not decode at every point.
        let bigger = try #require(await cache.image(key: "lib/a", data: data, maxPixel: 400))
        #expect(bigger !== first)
        let nearby = try #require(await cache.image(key: "lib/a", data: data, maxPixel: 210))
        #expect(nearby === cache.cached(key: "lib/a", maxPixel: 250))
    }

    @Test func bytesThatAreNotAnImageAreNil() async {
        let cache = ThumbnailImages()
        #expect(await cache.image(key: "lib/x", data: Data("not a jpeg".utf8), maxPixel: 200) == nil)
    }
}
