import Foundation

/// What a long-term average spectrum says about where a sound track has
/// been: how far up it goes and how abruptly it stops, and whether the
/// narrow tones of an analog video chain are sitting in it.
public enum AudioSpectrumReading {
    /// `power` is the averaged power spectrum from 0 to Nyquist.
    public static func measure(
        power: [Float], sampleRate: Double, prefix: String, into findings: inout SignalFindings
    ) {
        let binWidth = sampleRate / 2 / Double(power.count)
        guard binWidth > 0, power.count >= 1024 else { return }
        let levels = smoothedDecibels(power, reachHz: 100, binWidth: binWidth)

        // Below 100 Hz is rumble and DC; the programme's level is above it.
        let firstBin = Int(100 / binWidth)
        guard firstBin < levels.count, let loudest = levels[firstBin...].max() else { return }

        // Bandwidth is where the spectrum falls a given depth below its
        // loudest part and never comes back. Tape and low-bitrate web
        // audio stop near 10 to 12 kHz, FM and 128 kbit/s MP3 near 15 to
        // 16, and a digital master runs to 20 and beyond.
        func lastBin(within depth: Float) -> Int? {
            levels.indices.reversed().first { $0 >= firstBin && levels[$0] >= loudest - depth }
        }
        guard let deep = lastBin(within: 60), let shallow = lastBin(within: 40) else { return }
        findings.measure("\(prefix).rolloffHz", Double(deep) * binWidth)
        findings.measure("\(prefix).bandwidth40Hz", Double(shallow) * binWidth)
        findings.measure("\(prefix).nyquistFill", Double(deep) * binWidth / (sampleRate / 2))

        // How fast it goes: a codec's low-pass is a wall, tens of decibels
        // in a few hundred hertz; an analog chain rolls away gently.
        let half = Int(500 / binWidth)
        if shallow - half >= firstBin, shallow + half < levels.count {
            findings.measure(
                "\(prefix).rolloffSteepnessDbPerKhz", Double(levels[shallow - half] - levels[shallow + half]))
        }

        // The horizontal scan of a nearby CRT, or of the recorder itself:
        // 15 625 Hz in 625-line countries, 15 734 Hz in 525-line ones.
        var whistle: (level: Double, hertz: Double)?
        for hertz in [15_625.0, 15_734.27] where hertz + 500 < sampleRate / 2 {
            guard let level = prominence(power, at: hertz, binWidth: binWidth, toneHz: 12, floorHz: 400)
            else { continue }
            if level > (whistle?.level ?? -.infinity) { whistle = (level, hertz) }
        }
        if let whistle {
            findings.measure("\(prefix).lineWhistleDb", whistle.level)
            if whistle.level >= 10 { findings.measure("\(prefix).lineWhistleHz", whistle.hertz) }
        }
    }

    /// Mains hum in the quietest passages: how far 50 Hz and its first two
    /// harmonics stand above what is around them, and the same for 60 Hz.
    /// Which one is there says which side of the Atlantic the machine was
    /// plugged in on.
    public static func measureHum(power: [Float], sampleRate: Double, into findings: inout SignalFindings) {
        let binWidth = sampleRate / 2 / Double(power.count)
        guard binWidth > 0, binWidth < 5 else { return }
        for base in [50.0, 60.0] {
            let harmonics = [1.0, 2, 3].compactMap {
                prominence(power, at: base * $0, binWidth: binWidth, toneHz: 3, floorHz: 25)
            }
            guard harmonics.count == 3 else { continue }
            findings.measure("audio.hum\(Int(base))Db", harmonics.reduce(0, +) / 3)
        }
    }

    /// Decibels by which the strongest bin within `toneHz` of `hertz`
    /// stands above the median of its surroundings out to `floorHz`.
    static func prominence(
        _ power: [Float], at hertz: Double, binWidth: Double, toneHz: Double, floorHz: Double
    ) -> Double? {
        let centre = Int((hertz / binWidth).rounded())
        let tone = max(Int(toneHz / binWidth), 1), reach = Int(floorHz / binWidth)
        guard centre - reach >= 1, centre + reach < power.count, reach > tone * 2 else { return nil }
        guard let peak = power[centre - tone...centre + tone].max() else { return nil }
        let around = (Array(power[centre - reach..<centre - tone * 2])
            + Array(power[centre + tone * 2 + 1...centre + reach])).sorted()
        guard !around.isEmpty else { return nil }
        let floor = around[around.count / 2]
        guard floor > 0, peak > 0 else { return nil }
        return Double(10 * log10(peak / floor))
    }

    static func smoothedDecibels(_ power: [Float], reachHz: Double, binWidth: Double) -> [Float] {
        let reach = max(Int(reachHz / binWidth), 1)
        // A running sum, so smoothing eight thousand bins stays linear.
        var prefix = [Double](repeating: 0, count: power.count + 1)
        for (index, value) in power.enumerated() { prefix[index + 1] = prefix[index] + Double(value) }
        return power.indices.map { bin in
            let low = max(bin - reach, 0), high = min(bin + reach, power.count - 1)
            let mean = (prefix[high + 1] - prefix[low]) / Double(high - low + 1)
            return Float(10 * log10(max(mean, 1e-30)))
        }
    }
}
