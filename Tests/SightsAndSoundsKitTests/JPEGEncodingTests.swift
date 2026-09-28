import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import SightsAndSoundsKit

/// Thumbnails are encoded with ImageIO, which every Apple platform has —
/// not AppKit's NSBitmapImageRep, which kept `import AppKit` in a Kit
/// meant to carry over to iOS and tvOS unchanged.
@Suite struct JPEGEncodingTests {
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func anImageEncodesToAWholeJPEGOfTheSameSize() throws {
        let data = try #require(JPEG.data(from: try image(width: 64, height: 36), quality: 0.8))
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
        #expect(data.suffix(2) == Data([0xFF, 0xD9]))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 64)
        #expect(decoded.height == 36)
    }
}
