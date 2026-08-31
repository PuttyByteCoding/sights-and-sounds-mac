import AppKit
import AVFoundation
import Foundation
import SightsAndSoundsKit

/// Stills for the evidence strip, seeked to the moment a string was read.
///
/// **Not `ScrubPreviewProvider`.** That one buckets time to five seconds
/// and asks the generator for keyframe tolerance to the same width,
/// because a hover pass over a scrubber wants speed and any nearby frame
/// will do. Here the timestamp *is* the content: spec 14 §8 shows the
/// frame at the moment the string was read so the operator can answer
/// "is this really a band name?" without opening ten items. A frame five
/// seconds off is a frame the text is not on, which answers nothing —
/// so this generator seeks tight and pays for it.
///
/// Metadata and path candidates have no moment, so they fall back to the
/// item's ordinary grid thumbnail rather than a frame at zero.
actor EvidenceFrameProvider {
    static let shared = EvidenceFrameProvider()

    private let memory = NSCache<NSString, NSData>()
    private var generators: [UUID: AVAssetImageGenerator] = [:]

    init() {
        memory.countLimit = 300
    }

    func frame(itemID: UUID, fileURL: URL, atSeconds seconds: Double) async -> Data? {
        // Tenths, not seconds: two lines read a second apart are two
        // different stills, and rounding them together would silently
        // show one of them the other's frame.
        let key = "\(itemID)/\(Int(seconds * 10))" as NSString
        if let cached = memory.object(forKey: key) { return cached as Data }

        let generator = generators[itemID] ?? {
            let made = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
            made.appliesPreferredTrackTransform = true
            made.maximumSize = CGSize(width: 480, height: 480)
            // Half a second either way. Not `.zero`: an exact seek on a
            // long-GOP encode decodes from the previous keyframe and can
            // take seconds per frame, and the strip draws several at once.
            made.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            made.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            generators[itemID] = made
            return made
        }()

        // The callback API bridged by a continuation, as in
        // ScrubPreviewProvider: the generator never leaves the actor, and
        // only Sendable data crosses back.
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let data: Data? = await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, cgImage, _, result, _ in
                guard result == .succeeded, let cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                continuation.resume(
                    returning: rep.representation(
                        using: .jpeg, properties: [.compressionFactor: 0.75]))
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
