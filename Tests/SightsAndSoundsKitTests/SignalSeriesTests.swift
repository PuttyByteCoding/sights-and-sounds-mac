import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// The curves a reading came from are kept so the reading can change
/// later without decoding again. What is kept has to be close enough to
/// read the same numbers from.
@Suite struct SignalSeriesTests {

    @Test func aPackedSpectrumComesBackWithinHalfADecibel() {
        // A picture's kind of curve: falling as 1/f^2.5 over 100 dB.
        let power = (0..<1024).map { bin in bin == 0 ? Float(0) : 1e10 / pow(Float(bin), 2.5) }
        let packed = SpectrumPacking.pack(power)
        #expect(packed.count == 260)
        let points = SpectrumPacking.unpack(packed, length: power.count)
        #expect(points.count == 256)
        for point in points where point.bin >= 1 {
            let expected = 1e10 / pow(Float(point.bin), 2.5)
            let error = abs(10 * log10(point.power) - 10 * log10(expected))
            // Half a decibel of quantisation, plus the width of the bin
            // the point averages over, which is widest at the top.
            #expect(error < 1.5, "bin \(point.bin): \(error) dB")
        }
        #expect(points.first!.bin == 1)
        #expect(points.last!.bin > 1000)
    }

    @Test func packedPointsCoverEveryBinOnceInOrder() {
        let ranges = SpectrumPacking.ranges(length: 512)
        #expect(ranges.first?.lowerBound == 1)
        #expect(ranges.last?.upperBound == 511)
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound + 1 == b.lowerBound) }
        // A curve shorter than the point count still packs.
        #expect(SpectrumPacking.pack([Float](repeating: 1, count: 100)).count == 260)
    }

    @Test func aSpectrumIsKeptWithTheReadingAndGoesWithIt() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Series")
        let source = Source(name: "S", rootPath: TestRoots.unreachable("series"))
        let item = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { db in
            try source.insert(db)
            try item.insert(db)
        }
        let whole = PictureGeometry.ActiveArea(left: 0, top: 0, width: 640, height: 360)
        let frame = SyntheticPicture.upscaledNoise(width: 640, height: 360, sourceWidth: 320, sourceHeight: 180)
        let findings = DetailSpectrum.measure([frame], in: whole)
        #expect(findings.series.map(\.key) == ["detail.spectrumAcross", "detail.spectrumDown"])

        try library.recordSignalStage(itemID: item.id, stage: "pictureStills", version: 3, findings: findings)
        let stored = try library.signalSeries(itemID: item.id)
        #expect(stored.count == 2)
        #expect(stored[0].length == 256)  // a 512-point FFT fits in 640 samples
        #expect(stored[0].points.count == 260)
        #expect(stored[0].encoding == "logdb8")

        // The stored curve reads the same way as the live one did.
        let unpacked = SpectrumPacking.unpack(stored[0].points, length: stored[0].length)
        let fromStored = DetailSpectrum.cutoff(ofPower: Self.resample(unpacked, length: stored[0].length))!
        let live = DetailSpectrum.horizontal(frame, in: whole)!
        #expect(abs(fromStored.fraction - live.fraction) < 0.05)
        #expect(fromStored.noiseLimited == live.noiseLimited)

        try library.forgetSignalStage(itemID: item.id, stage: "pictureStills")
        #expect(try library.signalSeries(itemID: item.id).isEmpty)
    }

    /// Back to a full-length curve by holding each point across its bins.
    static func resample(_ points: [(bin: Double, power: Float)], length: Int) -> [Float] {
        var power = [Float](repeating: 0, count: length)
        for (range, point) in zip(SpectrumPacking.ranges(length: length), points) {
            for bin in range { power[bin] = point.power }
        }
        return power
    }
}
