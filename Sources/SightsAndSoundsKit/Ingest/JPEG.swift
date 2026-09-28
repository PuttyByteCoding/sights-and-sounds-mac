import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// JPEG encoding through ImageIO, which every Apple platform has. The
/// thumbnail job used AppKit's NSBitmapImageRep, the one reason the Kit
/// imported AppKit — and the Kit is the part meant to carry over to the
/// iOS, iPadOS and tvOS apps unchanged.
enum JPEG {
    static func data(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
