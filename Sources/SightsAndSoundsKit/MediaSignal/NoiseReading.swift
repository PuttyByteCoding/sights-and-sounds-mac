import Accelerate
import Foundation

/// The random texture in a picture, measured where there is nothing else:
/// how much of it there is, whether it grows in the shadows or the
/// mid-tones, and whether it has a grain to it.
///
/// Noise is measured in the flattest blocks of each frame, since anywhere
/// else it cannot be told from detail. Three things about it point in
/// different directions. Sensor noise is strongest in the shadows; film
/// grain is strongest in the mid-tones. Noise that is as correlated down
/// as across, over more than a pixel, was scaled up with the picture.
/// Noise that runs along the lines and not between them is tape.
public enum NoiseReading {
    static let blockSize = 16

    struct Block {
        var mean: Float
        var deviation: Float
        var chromaDeviation: Float?
        var across: Float
        var down: Float
    }

    public static func measure(_ frames: [PictureFrame], in area: PictureGeometry.ActiveArea) -> SignalFindings {
        var findings = SignalFindings()
        var sigmas: [(Double, Double)] = []
        var flat: [Block] = []
        for frame in frames {
            let blocks = flatBlocks(frame, in: area)
            guard blocks.count >= 8 else { continue }
            flat += blocks
            sigmas.append((
                frame.positionSeconds,
                FrameSummary.percentile(blocks.map { Double($0.deviation) }, 0.5) ?? 0))
        }
        guard !flat.isEmpty else { return findings }
        FrameSummary.record("noise.sigma", sigmas, into: &findings)
        findings.measure("noise.flatBlocks", Double(flat.count))

        func typical(_ blocks: [Block], _ value: (Block) -> Float?) -> Double? {
            let values = blocks.compactMap(value).map(Double.init)
            return values.count >= 8 ? FrameSummary.percentile(values, 0.5) : nil
        }
        let shadows = typical(flat.filter { $0.mean < 70 }) { $0.deviation }
        let mids = typical(flat.filter { $0.mean >= 70 && $0.mean < 160 }) { $0.deviation }
        let highlights = typical(flat.filter { $0.mean >= 160 }) { $0.deviation }
        findings.measure("noise.sigmaShadows", shadows)
        findings.measure("noise.sigmaMidtones", mids)
        findings.measure("noise.sigmaHighlights", highlights)
        if let shadows, let mids, shadows > 0.05 { findings.measure("noise.midtoneToShadowRatio", mids / shadows) }

        findings.measure("noise.chromaSigma", typical(flat) { $0.chromaDeviation })
        // Only where there is noise to correlate: the neighbours of a
        // perfectly clean block correlate at whatever rounding decides.
        let noisy = flat.filter { $0.deviation > 0.6 }
        if let across = typical(noisy, { $0.across }), let down = typical(noisy, { $0.down }) {
            findings.measure("noise.horizontalCorrelation", across)
            findings.measure("noise.verticalCorrelation", down)
            findings.measure("noise.anisotropy", across - down)
        }
        return findings
    }

    /// The flattest blocks of a frame, leaving out any that are clipped to
    /// black or white, where there is no noise left to see.
    static func flatBlocks(_ frame: PictureFrame, in area: PictureGeometry.ActiveArea) -> [Block] {
        let size = blockSize
        guard area.width >= size * 4, area.height >= size * 4,
              area.left + area.width <= frame.width, area.top + area.height <= frame.height
        else { return [] }
        let hasChroma = !frame.cb.isEmpty && frame.chromaWidth * 2 == frame.width
            && frame.chromaHeight * 2 == frame.height

        var blocks: [Block] = []
        var pixels = [Float](repeating: 0, count: size * size)
        for top in stride(from: area.top, to: area.top + area.height - size + 1, by: size) {
            for left in stride(from: area.left, to: area.left + area.width - size + 1, by: size) {
                for row in 0..<size {
                    let start = (top + row) * frame.width + left
                    pixels.replaceSubrange(row * size..<(row + 1) * size, with: frame.luma[start..<start + size])
                }
                let mean = vDSP.mean(pixels)
                guard mean > 24, mean < 228 else { continue }
                let residual = detrended(pixels, size: size)
                let deviation = vDSP.rootMeanSquare(residual)
                var block = Block(mean: mean, deviation: deviation, across: 0, down: 0)
                let energy = vDSP.sumOfSquares(residual)
                if energy > 0 {
                    var across: Float = 0, down: Float = 0
                    for row in 0..<size {
                        for column in 0..<size {
                            let here = residual[row * size + column]
                            if column + 1 < size { across += here * residual[row * size + column + 1] }
                            if row + 1 < size { down += here * residual[(row + 1) * size + column] }
                        }
                    }
                    // Each sum has 15/16 of the products the energy has.
                    let scale = Float(size) / Float(size - 1)
                    block.across = across / energy * scale
                    block.down = down / energy * scale
                }
                if hasChroma {
                    let half = size / 2
                    var chroma = [Float](repeating: 0, count: half * half)
                    for row in 0..<half {
                        let start = (top / 2 + row) * frame.chromaWidth + left / 2
                        chroma.replaceSubrange(row * half..<(row + 1) * half, with: frame.cb[start..<start + half])
                    }
                    block.chromaDeviation = vDSP.rootMeanSquare(detrended(chroma, size: half))
                }
                blocks.append(block)
            }
        }
        // The flattest tenth of each tonal band separately. Taken over the
        // whole frame, the flattest blocks would all come from whichever
        // band has the least noise, and the comparison between bands, which
        // is the point, would have nothing to compare.
        return [0..<70, 70..<160, 160..<256].flatMap { band -> [Block] in
            let inBand = blocks.filter { band.contains(Int($0.mean)) }.sorted { $0.deviation < $1.deviation }
            return Array(inBand.prefix(max(inBand.count / 10, min(inBand.count, 8))))
        }
    }

    /// The block with its own tilt taken out: a smooth gradient across a
    /// wall or a sky is not noise, and would be counted as it otherwise.
    static func detrended(_ pixels: [Float], size: Int) -> [Float] {
        let mean = vDSP.mean(pixels)
        let centre = Float(size - 1) / 2
        var slopeX: Float = 0, slopeY: Float = 0, spread: Float = 0
        for row in 0..<size {
            for column in 0..<size {
                let value = pixels[row * size + column] - mean
                slopeX += value * (Float(column) - centre)
                slopeY += value * (Float(row) - centre)
                spread += (Float(column) - centre) * (Float(column) - centre)
            }
        }
        guard spread > 0 else { return pixels.map { $0 - mean } }
        slopeX /= spread
        slopeY /= spread
        return (0..<size * size).map { index in
            pixels[index] - mean - slopeX * (Float(index % size) - centre) - slopeY * (Float(index / size) - centre)
        }
    }
}
