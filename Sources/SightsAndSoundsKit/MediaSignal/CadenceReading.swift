import Foundation

/// Reads a run of frame-to-frame differences for the rhythms that frame
/// rate conversion leaves behind.
///
/// Film carried at video rate repeats or blends frames on a fixed beat:
/// one repeat in five for 24 into 30, one in two for 12 or 15 into 30, one
/// in 25 for 24 into 25. A web clip shot at 15 frames a second and padded
/// to 30 repeats every other frame. None of this is in the container,
/// which says only "30", and all of it survives re-encoding, because an
/// encoder spends almost nothing on a frame identical to the last and so
/// keeps it identical.
public enum CadenceReading {
    public struct Reading: Equatable, Sendable {
        /// Share of frames that repeat the one before.
        public var duplicateFraction = 0.0
        /// The beat the repeats fall on, when they fall on one.
        public var duplicatePeriod: Int?
        /// How much of the repeating is on that beat, 0...1.
        public var duplicateRegularity = 0.0
        /// Lag, in frames, at which the amount of motion repeats itself.
        public var motionPeriod: Int?
        /// Strength of that repetition, 0...1.
        public var motionPeriodStrength = 0.0
        public var sceneCuts = 0
    }

    /// `differences[i]` is the mean absolute luma difference between frame
    /// `i + 1` and frame `i`, in 8-bit code values.
    public static func read(_ differences: [Double]) -> Reading {
        var reading = Reading()
        guard differences.count >= 12 else { return reading }

        let moving = differences.filter { $0 > 0 }.sorted()
        let typical = moving.isEmpty ? 0 : moving[moving.count / 2]
        // A repeat is not just "small": it is small next to what the file
        // usually does. A locked-off shot of a wall has small differences
        // everywhere and no repeats at all.
        let repeatLimit = max(min(typical * 0.12, 0.6), 0.02)
        let cutLimit = max(typical * 6, 12)
        let isRepeat = differences.map { $0 <= repeatLimit }
        reading.sceneCuts = differences.count { $0 >= cutLimit }

        // Stretches with no motion at all say nothing about cadence: every
        // frame repeats, on every beat. Only repeats with motion either
        // side of them count.
        let active = differences.indices.filter { index in
            let nearby = differences[max(index - 3, 0)...min(index + 3, differences.count - 1)]
            return nearby.count { $0 > repeatLimit } >= 3
        }
        guard active.count >= 12 else { return reading }
        let repeats = active.filter { isRepeat[$0] }
        reading.duplicateFraction = Double(repeats.count) / Double(active.count)

        if repeats.count >= 3 {
            for period in 2...6 {
                var phases = [Int](repeating: 0, count: period)
                for index in repeats { phases[index % period] += 1 }
                let onBeat = Double(phases.max() ?? 0) / Double(repeats.count)
                // On one beat, and about as many as that beat predicts.
                let expected = 1 / Double(period)
                let plausible = abs(reading.duplicateFraction - expected) / expected < 0.35
                if onBeat >= 0.8, plausible, onBeat > reading.duplicateRegularity {
                    reading.duplicatePeriod = period
                    reading.duplicateRegularity = onBeat
                }
            }
        }

        // Pulldown that was blended or deinterlaced leaves no exact repeat,
        // only motion that comes in a repeating pattern of big and small
        // steps. Look for the beat in the motion, cuts and stills taken out.
        let motion = active.map { min(differences[$0], cutLimit) }
        if let beat = beat(in: motion) {
            reading.motionPeriod = beat.period
            reading.motionPeriodStrength = beat.strength
        }
        return reading
    }

    /// The lag, from 2 to 6, at which a series repeats itself, and how
    /// strongly (0...1). Nil when nothing repeats.
    public static func beat(in series: [Double]) -> (period: Int, strength: Double)? {
        // A pan that speeds up and slows down correlates with itself at
        // every lag, so each value is taken relative to the values around
        // it and only the beat is left.
        let centred = series.indices.map { index -> Double in
            let nearby = series[max(index - 3, 0)...min(index + 3, series.count - 1)]
            return series[index] - nearby.reduce(0, +) / Double(nearby.count)
        }
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return nil }
        var best: (period: Int, strength: Double)?
        for lag in 2...6 where series.count > lag * 4 {
            var sum = 0.0
            for index in lag..<centred.count { sum += centred[index] * centred[index - lag] }
            let strength = sum / energy
            // A beat at lag n also shows at 2n; the shortest lag wins ties.
            if strength > (best?.strength ?? 0) + 0.05 { best = (lag, strength) }
        }
        guard let best, best.strength >= 0.3 else { return nil }
        return best
    }
}
