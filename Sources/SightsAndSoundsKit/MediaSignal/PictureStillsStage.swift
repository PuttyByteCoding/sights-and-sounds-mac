import Foundation

/// Measures the picture from a handful of decoded stills: where the active
/// picture is, how much real detail it holds, what range and depth its
/// samples actually use, how much detail its colour carries, and what its
/// noise is like.
///
/// Everything here is evidence about the source rather than the encode.
/// Bars baked into the frame and a spectrum that stops well short of the
/// encoded size both survive transcoding, which is exactly why they are
/// worth having when the container can only describe the last encoder.
public struct PictureStillsStage: SignalStage {
    public let name = "pictureStills"
    public let version = 2
    public let kinds: Set<MediaKind> = [.video]

    public init() {}

    public func examine(_ file: SignalStageInput) async throws -> SignalFindings {
        let stills = try await FrameSampler.stills(of: file.url, isCancelled: file.isCancelled)
        guard !stills.frames.isEmpty else {
            throw SignalStageError("no frame with a picture in it could be decoded")
        }
        return Self.measure(stills)
    }

    static func measure(_ stills: FrameSampler.Stills) -> SignalFindings {
        var findings = SignalFindings()
        findings.measure("sampling.stillsUsed", Double(stills.frames.count))
        for (rejection, count) in stills.rejected {
            findings.measure("sampling.rejected.\(rejection.rawValue)", Double(count))
        }

        let geometry = PictureGeometry.measure(stills.frames, pixelAspectRatio: stills.pixelAspectRatio)
        findings.merge(geometry)

        guard let first = stills.frames.first else { return findings }
        let area = PictureGeometry.ActiveArea(
            left: Int(geometry.value("geometry.activeLeft") ?? 0),
            top: Int(geometry.value("geometry.activeTop") ?? 0),
            width: Int(geometry.value("geometry.activeWidth") ?? Double(first.width)),
            height: Int(geometry.value("geometry.activeHeight") ?? Double(first.height)))
        findings.merge(DetailSpectrum.measure(stills.frames, in: area))
        findings.merge(ColourReading.measure(stills.frames, in: area))
        findings.merge(ChromaReading.measure(stills.frames, in: area))
        findings.merge(NoiseReading.measure(stills.frames, in: area))
        return findings
    }
}
