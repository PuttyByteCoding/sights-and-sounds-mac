import Accelerate
import CoreVideo
import Foundation

/// One decoded frame as the codec stored it: a luma plane and two chroma
/// planes, never converted to RGB.
///
/// The conversion is what would destroy the evidence. Chroma bandwidth,
/// chroma offset, the range actually used and the occupancy of the low
/// bits all live in Y'CbCr and are smeared or gone in RGB. Samples are
/// floats on the 8-bit code scale whatever the file's depth, so a 10-bit
/// value keeps its fraction (code 64.25) and every measurement uses one
/// set of thresholds.
public struct PictureFrame: Sendable {
    public let width: Int
    public let height: Int
    public let luma: [Float]
    public let chromaWidth: Int
    public let chromaHeight: Int
    public let cb: [Float]
    public let cr: [Float]
    public let positionSeconds: Double
    /// Bits per sample in the decoded buffer.
    public let bitDepth: Int

    public init(
        width: Int, height: Int, luma: [Float], chromaWidth: Int = 0, chromaHeight: Int = 0,
        cb: [Float] = [], cr: [Float] = [], positionSeconds: Double = 0, bitDepth: Int = 8
    ) {
        self.width = width
        self.height = height
        self.luma = luma
        self.chromaWidth = chromaWidth
        self.chromaHeight = chromaHeight
        self.cb = cb
        self.cr = cr
        self.positionSeconds = positionSeconds
        self.bitDepth = bitDepth
    }

    /// The mean of each row of the luma plane.
    public func rowMeans() -> [Float] {
        luma.withUnsafeBufferPointer { plane in
            (0..<height).map { row in
                var mean: Float = 0
                vDSP_meanv(plane.baseAddress! + row * width, 1, &mean, vDSP_Length(width))
                return mean
            }
        }
    }

    /// The mean of each column of the luma plane.
    public func columnMeans() -> [Float] {
        luma.withUnsafeBufferPointer { plane in
            (0..<width).map { column in
                var mean: Float = 0
                vDSP_meanv(plane.baseAddress! + column, width, &mean, vDSP_Length(height))
                return mean
            }
        }
    }

    public func lumaMeanAndDeviation() -> (mean: Float, deviation: Float) {
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(luma, 1, nil, 1, &mean, &deviation, vDSP_Length(luma.count))
        return (mean, deviation)
    }
}

extension PictureFrame {
    /// Copy a bi-planar Y'CbCr pixel buffer (8-bit `420v`/`420f` or 10-bit
    /// `x420`/`xf20`) into planes. Nil for any other layout.
    init?(_ buffer: CVPixelBuffer, positionSeconds: Double, lumaOnly: Bool = false) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            tenBit = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            tenBit = true
        default:
            return nil
        }
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        // Sequences are measured on luma alone, a few hundred frames at a
        // time; skipping the chroma copy is most of the cost of a frame.
        let chromaWidth = lumaOnly ? 0 : CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = lumaOnly ? 0 : CVPixelBufferGetHeightOfPlane(buffer, 1)
        guard width > 0, height > 0,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        var luma = [Float](repeating: 0, count: width * height)
        var cb = [Float](repeating: 0, count: chromaWidth * chromaHeight)
        var cr = [Float](repeating: 0, count: chromaWidth * chromaHeight)

        if tenBit {
            // Ten significant bits in the top of each 16: 1/64 gives the
            // 10-bit code, another 1/4 puts it on the 8-bit scale.
            var scale: Float = 1.0 / 256
            for row in 0..<height {
                let source = (lumaBase + row * lumaStride).assumingMemoryBound(to: UInt16.self)
                luma.withUnsafeMutableBufferPointer { plane in
                    let target = plane.baseAddress! + row * width
                    vDSP_vfltu16(source, 1, target, 1, vDSP_Length(width))
                    vDSP_vsmul(target, 1, &scale, target, 1, vDSP_Length(width))
                }
            }
            for row in 0..<chromaHeight {
                let source = (chromaBase + row * chromaStride).assumingMemoryBound(to: UInt16.self)
                cb.withUnsafeMutableBufferPointer { plane in
                    let target = plane.baseAddress! + row * chromaWidth
                    vDSP_vfltu16(source, 2, target, 1, vDSP_Length(chromaWidth))
                    vDSP_vsmul(target, 1, &scale, target, 1, vDSP_Length(chromaWidth))
                }
                cr.withUnsafeMutableBufferPointer { plane in
                    let target = plane.baseAddress! + row * chromaWidth
                    vDSP_vfltu16(source + 1, 2, target, 1, vDSP_Length(chromaWidth))
                    vDSP_vsmul(target, 1, &scale, target, 1, vDSP_Length(chromaWidth))
                }
            }
        } else {
            for row in 0..<height {
                let source = (lumaBase + row * lumaStride).assumingMemoryBound(to: UInt8.self)
                luma.withUnsafeMutableBufferPointer { plane in
                    vDSP_vfltu8(source, 1, plane.baseAddress! + row * width, 1, vDSP_Length(width))
                }
            }
            for row in 0..<chromaHeight {
                let source = (chromaBase + row * chromaStride).assumingMemoryBound(to: UInt8.self)
                cb.withUnsafeMutableBufferPointer { plane in
                    vDSP_vfltu8(source, 2, plane.baseAddress! + row * chromaWidth, 1, vDSP_Length(chromaWidth))
                }
                cr.withUnsafeMutableBufferPointer { plane in
                    vDSP_vfltu8(source + 1, 2, plane.baseAddress! + row * chromaWidth, 1, vDSP_Length(chromaWidth))
                }
            }
        }

        self.init(
            width: width, height: height, luma: luma, chromaWidth: chromaWidth,
            chromaHeight: chromaHeight, cb: cb, cr: cr, positionSeconds: positionSeconds,
            bitDepth: tenBit ? 10 : 8)
    }
}

extension PictureFrame {
    /// The luma of `area`, averaged across in whole-pixel groups until it
    /// is no wider than `maxWidth`. Rows are left alone: interlacing and
    /// line doubling live in the rows, and averaging them away would
    /// remove what the sequence measures are looking for.
    public func working(in area: PictureGeometry.ActiveArea? = nil, maxWidth: Int = 960) -> PictureFrame {
        let area = area ?? .init(left: 0, top: 0, width: width, height: height)
        let factor = max((area.width + maxWidth - 1) / maxWidth, 1)
        let outWidth = area.width / factor
        guard outWidth > 0, area.height > 0,
              area.left + area.width <= width, area.top + area.height <= height
        else { return self }
        if factor == 1, area.width == width, area.height == height { return self }

        var out = [Float](repeating: 0, count: outWidth * area.height)
        let box = [Float](repeating: 1 / Float(factor), count: factor)
        luma.withUnsafeBufferPointer { plane in
            out.withUnsafeMutableBufferPointer { target in
                for row in 0..<area.height {
                    vDSP_desamp(
                        plane.baseAddress! + (area.top + row) * width + area.left, vDSP_Stride(factor), box,
                        target.baseAddress! + row * outWidth, vDSP_Length(outWidth), vDSP_Length(factor))
                }
            }
        }
        return PictureFrame(
            width: outWidth, height: area.height, luma: out, positionSeconds: positionSeconds,
            bitDepth: bitDepth)
    }
}

/// Per-frame values and the two summaries every picture measurement is
/// reported by: the median (what the file usually does) and the ninetieth
/// percentile (the most it can do).
public enum FrameSummary {
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// Frame rows plus median and high rows for one key.
    public static func record(
        _ key: String, _ values: [(positionSeconds: Double, value: Double)],
        into findings: inout SignalFindings
    ) {
        let usable = values.filter(\.value.isFinite)
        guard !usable.isEmpty else { return }
        for entry in usable {
            findings.measured.append(.init(key, entry.value, scope: .frame, at: entry.positionSeconds))
        }
        let numbers = usable.map(\.value)
        if let median = percentile(numbers, 0.5) {
            findings.measured.append(.init(key, median, scope: .median))
        }
        if let high = percentile(numbers, 0.9) {
            findings.measured.append(.init(key, high, scope: .high))
        }
    }
}
