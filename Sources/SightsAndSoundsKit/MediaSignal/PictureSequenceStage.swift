import Foundation

/// Decodes a few stretches of the file frame by frame and measures its
/// cadence and what interlacing left behind.
///
/// The declared scan type is the transcoder's. What is measured here is
/// kept in three separate statements, because they are three different
/// things: whether the frames in this file are combed now; whether there
/// is a sign the material was interlaced once (line doubling, a bob
/// deinterlacer's flutter, blended fields); and whether its motion runs to
/// a film or a low-frame-rate beat. Finding no comb teeth says only the
/// first of these, and nothing about the source.
public struct PictureSequenceStage: SignalStage {
    public let name = "pictureSequences"
    public let version = 1
    public let kinds: Set<MediaKind> = [.video]
    public let pass = 3

    public init() {}

    public func examine(_ file: SignalStageInput) async throws -> SignalFindings {
        // The active picture: bars are still, identical frame to frame, and
        // would water down every difference measured here.
        let stills = try await FrameSampler.stills(
            of: file.url, fractions: [0.15, 0.35, 0.5, 0.65, 0.85], isCancelled: file.isCancelled)
        let geometry = PictureGeometry.measure(stills.frames, pixelAspectRatio: stills.pixelAspectRatio)
        var area: PictureGeometry.ActiveArea?
        if let width = geometry.value("geometry.activeWidth"), let height = geometry.value("geometry.activeHeight") {
            area = .init(
                left: Int(geometry.value("geometry.activeLeft") ?? 0),
                top: Int(geometry.value("geometry.activeTop") ?? 0), width: Int(width), height: Int(height))
        }

        var readings: [(start: Double, frames: Int, reading: SequenceMeter.Reading)] = []
        for window in FrameSampler.windows(durationSeconds: stills.durationSeconds) {
            try await file.checkCancellation()
            let meter = SequenceMeter()
            try await FrameSampler.sequence(
                of: file.url, from: window.start, seconds: window.seconds, area: area,
                isCancelled: file.isCancelled
            ) { meter.consume($0) }
            if meter.frameCount >= 24 { readings.append((window.start, meter.frameCount, meter.reading())) }
        }
        guard !readings.isEmpty else {
            throw SignalStageError("no stretch of at least 24 frames could be decoded")
        }
        return Self.findings(from: readings)
    }

    static func findings(
        from readings: [(start: Double, frames: Int, reading: SequenceMeter.Reading)]
    ) -> SignalFindings {
        var findings = SignalFindings()
        findings.measure("sampling.windowsUsed", Double(readings.count))
        findings.measure("sampling.windowFrames", Double(readings.reduce(0) { $0 + $1.frames }))

        func record(_ key: String, _ value: (SequenceMeter.Reading) -> Double) {
            for entry in readings {
                findings.measured.append(.init(key, value(entry.reading), scope: .window, at: entry.start))
            }
            let values = readings.map { value($0.reading) }
            if let median = FrameSummary.percentile(values, 0.5) {
                findings.measured.append(.init(key, median, scope: .median))
            }
            if let high = values.max() { findings.measured.append(.init(key, high, scope: .high)) }
        }
        record("cadence.duplicateFraction") { $0.cadence.duplicateFraction }
        record("cadence.blendedFraction") { $0.blendedFraction }
        record("cadence.motionPeriodStrength") { $0.cadence.motionPeriodStrength }
        record("compression.sharpnessBeatStrength") { $0.sharpnessPeriodStrength }
        record("cadence.sceneCuts") { Double($0.cadence.sceneCuts) }
        record("interlace.combedShare") { $0.combedShareHigh }
        record("interlace.combedFrameFraction") { $0.combedFrameFraction }
        record("interlace.linePairAsymmetry") { $0.linePairAsymmetry }
        record("interlace.bobFlutter") { $0.bobFlutter }
        record("temporal.lumaFlicker") { $0.flicker }

        // A beat is believed when most of the windows that found one agree.
        func agreed(_ periods: [Int?]) -> Int? {
            let found = periods.compactMap { $0 }
            guard let commonest = Set(found).max(by: { a, b in
                found.count { $0 == a } < found.count { $0 == b }
            }) else { return nil }
            let support = found.count { $0 == commonest }
            return support * 2 > periods.count ? commonest : nil
        }
        findings.measure(
            "cadence.duplicatePeriod", agreed(readings.map(\.reading.cadence.duplicatePeriod)).map(Double.init))
        findings.measure(
            "cadence.motionPeriod", agreed(readings.map(\.reading.cadence.motionPeriod)).map(Double.init))
        findings.measure(
            "compression.sharpnessBeatPeriod", agreed(readings.map(\.reading.sharpnessPeriod)).map(Double.init))
        findings.measure(
            "interlace.combedPeriod", agreed(readings.map(\.reading.combedPeriod)).map(Double.init))
        return findings
    }
}
