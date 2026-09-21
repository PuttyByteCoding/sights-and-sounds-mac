import Foundation

/// Where the picture actually is inside the encoded frame.
///
/// A 4:3 programme carried in a 16:9 file, or a widescreen film carried in
/// a 4:3 one, has black bars that were encoded as picture. The container
/// knows nothing about them. They survive every later re-encode, which
/// makes the active picture's shape some of the most durable evidence of
/// what the material originally was.
public enum PictureGeometry {
    public struct ActiveArea: Equatable, Sendable {
        public var left: Int
        public var top: Int
        public var width: Int
        public var height: Int
    }

    /// Luma below this is "black enough to be a border". Video-range black
    /// is code 16, and borders that came through an analog capture sit a
    /// little above it and carry noise, so the limit is generous; a dark
    /// scene cannot fool it because the bound is taken across many frames.
    static let blackLimit: Float = 32

    /// The part of the per-frame bounds that is trusted. A border is as
    /// small as the frames that show it smallest, since a dark frame only
    /// ever makes a border look bigger; but a subtitle or a channel logo
    /// inside a bar makes it look smaller in the few frames that have one,
    /// so the very smallest values are not taken at their word either.
    static let trustedFraction = 0.2

    /// Borders thinner than this fraction of the frame are rounding in an
    /// encoder's crop, not letterboxing.
    static let meaningfulBorder = 0.03

    public static let standardAspects: [(name: String, ratio: Double)] = [
        ("1.33", 4.0 / 3), ("1.37", 1.375), ("1.66", 5.0 / 3), ("1.78", 16.0 / 9),
        ("1.85", 1.85), ("2.00", 2.0), ("2.20", 2.2), ("2.35", 2.35), ("2.39", 2.39),
    ]

    public static func measure(_ frames: [PictureFrame], pixelAspectRatio: Double = 1) -> SignalFindings {
        var findings = SignalFindings()
        guard let first = frames.first else { return findings }
        let width = first.width, height = first.height
        let usable = frames.filter { $0.width == width && $0.height == height }

        var tops: [Double] = [], bottoms: [Double] = [], lefts: [Double] = [], rights: [Double] = []
        var profiles: [(rows: [Float], columns: [Float])] = []
        for frame in usable {
            let rows = frame.rowMeans(), columns = frame.columnMeans()
            guard let top = rows.firstIndex(where: { $0 > blackLimit }),
                  let bottom = rows.lastIndex(where: { $0 > blackLimit }),
                  let left = columns.firstIndex(where: { $0 > blackLimit }),
                  let right = columns.lastIndex(where: { $0 > blackLimit })
            else { continue }  // a black frame bounds nothing
            tops.append(Double(top))
            bottoms.append(Double(height - 1 - bottom))
            lefts.append(Double(left))
            rights.append(Double(width - 1 - right))
            profiles.append((rows, columns))
        }
        guard !tops.isEmpty else { return findings }

        func border(_ values: [Double]) -> Int {
            Int((FrameSummary.percentile(values, trustedFraction) ?? 0).rounded())
        }
        let top = border(tops), bottom = border(bottoms), left = border(lefts), right = border(rights)
        let active = ActiveArea(
            left: left, top: top, width: max(width - left - right, 1), height: max(height - top - bottom, 1))

        findings.measure("geometry.framesUsed", Double(tops.count))
        findings.measure("geometry.activeLeft", Double(active.left))
        findings.measure("geometry.activeTop", Double(active.top))
        findings.measure("geometry.activeWidth", Double(active.width))
        findings.measure("geometry.activeHeight", Double(active.height))

        let barsAboveAndBelow = Double(top + bottom) / Double(height)
        let barsAtTheSides = Double(left + right) / Double(width)
        findings.measure("geometry.letterboxFraction", barsAboveAndBelow)
        findings.measure("geometry.pillarboxFraction", barsAtTheSides)
        findings.measure("geometry.letterboxed", barsAboveAndBelow >= meaningfulBorder ? 1 : 0)
        findings.measure("geometry.pillarboxed", barsAtTheSides >= meaningfulBorder ? 1 : 0)
        // Bars that are not the same size on both sides were not added by
        // a tool centring a picture; they came with it.
        findings.measure("geometry.verticalOffCentre", Double(abs(top - bottom)) / Double(height))
        findings.measure("geometry.horizontalOffCentre", Double(abs(left - right)) / Double(width))

        let aspect = Double(active.width) * pixelAspectRatio / Double(active.height)
        findings.measure("geometry.activeAspectRatio", aspect)
        findings.measure("geometry.encodedAspectRatio", Double(width) * pixelAspectRatio / Double(height))
        if let standard = standardAspects.min(by: { abs($0.ratio - aspect) < abs($1.ratio - aspect) }),
           abs(standard.ratio - aspect) / standard.ratio < 0.025 {
            findings.measure("geometry.standardAspectRatio", standard.ratio)
        }

        guard barsAboveAndBelow >= meaningfulBorder || barsAtTheSides >= meaningfulBorder else {
            return findings
        }
        measureBorders(usable, active: active, profiles: profiles, into: &findings)
        return findings
    }

    /// What the bars are made of, and how hard their inner edge is.
    ///
    /// Bars a tool painted are one flat code value with a one-pixel edge.
    /// Bars that were captured with the picture carry its noise; bars that
    /// were later scaled with it have a soft edge several pixels wide.
    private static func measureBorders(
        _ frames: [PictureFrame], active: ActiveArea, profiles: [(rows: [Float], columns: [Float])],
        into findings: inout SignalFindings
    ) {
        guard let first = frames.first else { return }
        let width = first.width, height = first.height

        var levels: [Double] = [], noises: [Double] = []
        for frame in frames {
            var samples: [Float] = []
            // Keep clear of the edge itself, which belongs to the picture.
            let margin = 3
            for row in 0..<height {
                let inBar = row < active.top - margin || row >= active.top + active.height + margin
                for column in stride(from: 0, to: width, by: 2) {
                    let inSideBar = column < active.left - margin || column >= active.left + active.width + margin
                    if inBar || inSideBar { samples.append(frame.luma[row * width + column]) }
                }
            }
            guard samples.count >= 64 else { continue }
            let mean = samples.reduce(0, +) / Float(samples.count)
            let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(samples.count)
            levels.append(Double(mean))
            noises.append(Double(variance.squareRoot()))
        }
        findings.measure("geometry.borderLevel", FrameSummary.percentile(levels, 0.5))
        findings.measure("geometry.borderNoise", FrameSummary.percentile(noises, 0.5))

        // Average the profiles, then count the samples it takes each edge
        // to climb from a tenth to nine tenths of the picture's level.
        func averaged(_ pick: ((rows: [Float], columns: [Float])) -> [Float]) -> [Float] {
            guard let length = profiles.first.map({ pick($0).count }) else { return [] }
            var sum = [Float](repeating: 0, count: length)
            for profile in profiles {
                for (index, value) in pick(profile).enumerated() { sum[index] += value }
            }
            return sum.map { $0 / Float(profiles.count) }
        }
        let rows = averaged(\.rows), columns = averaged(\.columns)
        var edges: [Double] = []
        if active.top > 0 { edges.append(edgeWidth(rows, at: active.top, inward: 1)) }
        if active.top + active.height < height {
            edges.append(edgeWidth(rows, at: active.top + active.height - 1, inward: -1))
        }
        if active.left > 0 { edges.append(edgeWidth(columns, at: active.left, inward: 1)) }
        if active.left + active.width < width {
            edges.append(edgeWidth(columns, at: active.left + active.width - 1, inward: -1))
        }
        findings.measure("geometry.borderEdgeWidth", FrameSummary.percentile(edges.filter { $0 >= 0 }, 0.5))
    }

    static func edgeWidth(_ profile: [Float], at edge: Int, inward: Int) -> Double {
        let reach = 12
        let inside = edge + inward * reach, outside = edge - inward * reach
        guard profile.indices.contains(inside), profile.indices.contains(outside) else { return -1 }
        let dark = profile[outside], bright = profile[inside]
        guard bright - dark > 8 else { return -1 }
        let low = dark + (bright - dark) * 0.1, high = dark + (bright - dark) * 0.9
        var between = 0
        var index = outside
        while index != inside {
            if profile[index] > low && profile[index] < high { between += 1 }
            index += inward
        }
        return Double(between)
    }
}
