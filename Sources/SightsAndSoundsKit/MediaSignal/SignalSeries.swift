import Foundation
import GRDB

/// A curve a stage read its numbers from, kept with the numbers.
///
/// The readings taken from a spectrum (where detail runs out, whether the
/// frame is noise-limited) are judgements, and the judgement will be
/// revised once there are files whose history is known to revise it
/// against. Revising it must not mean decoding the library again, so the
/// spectrum itself is stored: each frame's, for each direction, at 256
/// log-spaced points in half-decibel steps. About 8 KB a video.
public struct SignalSeries: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mediaSignalSeries"

    public var id: Int64?
    public var mediaItemID: UUID
    public var stage: String
    public var key: String
    public var positionSeconds: Double?
    /// How many bins the original curve had, so it can be mapped back.
    public var length: Int
    /// How `points` is packed. The one encoding so far is `logdb8`: a
    /// little-endian Float32 reference level in decibels, then 256 bytes,
    /// bin centres spaced logarithmically from bin 1 to `length`, each
    /// byte the level above the reference in half-decibel steps.
    public var encoding: String
    public var points: Data

    public init(
        mediaItemID: UUID = UUID(), stage: String, key: String, positionSeconds: Double?,
        length: Int, encoding: String = SpectrumPacking.encoding, points: Data
    ) {
        self.mediaItemID = mediaItemID
        self.stage = stage
        self.key = key
        self.positionSeconds = positionSeconds
        self.length = length
        self.encoding = encoding
        self.points = points
    }
}

/// Packs a power spectrum into a few hundred bytes and back.
public enum SpectrumPacking {
    public static let encoding = "logdb8"
    public static let pointCount = 256
    static let stepDecibels: Float = 0.5

    /// Bin ranges, one per point, spaced so that each point covers the
    /// same ratio of frequencies: the low end fine, the high end coarse,
    /// which is how the readings look at a spectrum too.
    static func ranges(length: Int) -> [ClosedRange<Int>] {
        guard length >= 2 else { return [] }
        let top = Double(length - 1)
        var ranges: [ClosedRange<Int>] = []
        var previousEnd = 0
        for point in 0..<pointCount {
            let edge = pow(top, Double(point + 1) / Double(pointCount))
            // At least one bin per point, and never past the end; a short
            // curve's last points all cover its last bin.
            let end = min(max(Int(edge.rounded()), previousEnd + 1), length - 1)
            let start = min(previousEnd + 1, length - 1)
            ranges.append(start...end)
            previousEnd = end
        }
        return ranges
    }

    public static func pack(_ power: [Float]) -> Data {
        let levels = ranges(length: power.count).map { range -> Float in
            let mean = power[range].reduce(0, +) / Float(range.count)
            return 10 * log10(max(mean, 1e-12))
        }
        // The reference sits at the top of the curve, so 127 dB of range
        // runs down from the loudest point: every spectrum keeps the same
        // resolution whatever its absolute level.
        let reference = (levels.max() ?? 0) - Float(255) * stepDecibels
        var data = withUnsafeBytes(of: reference.bitPattern.littleEndian) { Data($0) }
        data.append(contentsOf: levels.map { level -> UInt8 in
            UInt8(min(max(((level - reference) / stepDecibels).rounded(), 0), 255))
        })
        return data
    }

    /// The curve back, as (bin, power) pairs at the packed points.
    public static func unpack(_ data: Data, length: Int) -> [(bin: Double, power: Float)] {
        guard data.count == 4 + pointCount else { return [] }
        let bits = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let reference = Float(bitPattern: UInt32(littleEndian: bits))
        let bytes = [UInt8](data.dropFirst(4))
        return zip(ranges(length: length), bytes).map { range, byte in
            let decibels = Float(byte) * stepDecibels + reference
            let centre = Double(range.lowerBound + range.upperBound) / 2
            return (centre, pow(10, decibels / 10))
        }
    }
}

extension SignalFindings {
    public struct Curve: Equatable, Sendable {
        public var key: String
        public var positionSeconds: Double?
        public var length: Int
        public var points: Data
    }

    public mutating func keep(_ key: String, spectrum power: [Float], at positionSeconds: Double?) {
        guard power.count >= 2 else { return }
        series.append(Curve(
            key: key, positionSeconds: positionSeconds, length: power.count,
            points: SpectrumPacking.pack(power)))
    }
}

extension LibraryDatabase {
    public func signalSeries(itemID: UUID, key: String? = nil) throws -> [SignalSeries] {
        try writer.read { db in
            var request = SignalSeries.filter(sql: "mediaItemID = ?", arguments: [itemID])
            if let key { request = request.filter(sql: "key = ?", arguments: [key]) }
            return try request.order(sql: "key, positionSeconds").fetchAll(db)
        }
    }
}
