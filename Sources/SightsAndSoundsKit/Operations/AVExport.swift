import AVFoundation
import Foundation

/// Shared passthrough-export plumbing for the operation jobs, on the
/// modern throwing export API. The session lives and dies inside one
/// call; only primitives cross back.
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

        session.shouldOptimizeForNetworkUse = optimizeForNetworkUse
        if let timeRange { session.timeRange = timeRange }

        do {
            try await session.export(to: outputURL, as: .mp4)
        } catch {
            throw ExportFailure(message: "\(error)")
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        guard size > 0 else { throw ExportFailure(message: "export produced an empty file") }
    }
}
