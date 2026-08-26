import AVFoundation
import Foundation

/// Shared passthrough-export plumbing for the operation jobs. The session
/// is non-Sendable, so it lives and dies inside one call; only primitives
/// cross back (the ScrubPreviewProvider lesson, applied from the start).
enum AVExport {
    struct ExportFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Stream-copy `asset` (optionally a sub-range) to `outputURL` as MP4.
    /// Passthrough: no re-encode, exact stream copy — fast and lossless.
    static func passthrough(
        assetURL: URL, to outputURL: URL,
        timeRange: CMTimeRange? = nil,
        optimizeForNetworkUse: Bool = false
    ) async throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let asset = AVURLAsset(url: assetURL)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { throw ExportFailure(message: "passthrough export unavailable for this container") }

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = optimizeForNetworkUse
        if let timeRange { session.timeRange = timeRange }

        let failure: String? = await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume(returning: nil)
                case .cancelled:
                    continuation.resume(returning: "export cancelled")
                default:
                    continuation.resume(returning: session.error.map(String.init(describing:)) ?? "export failed")
                }
            }
        }
        if let failure { throw ExportFailure(message: failure) }

        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        guard size ?? 0 > 0 else { throw ExportFailure(message: "export produced an empty file") }
    }
}
