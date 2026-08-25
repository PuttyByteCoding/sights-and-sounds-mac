import Foundation

/// Pure downsampling for waveform rendering: raw PCM samples in, one peak
/// per display bucket out, normalized to 0…1 by the global peak.
public enum WaveformMath {
    public static func peaks(samples: [Float], bucketCount: Int) -> [Float] {
        guard bucketCount > 0, !samples.isEmpty else { return [] }
        let usableBuckets = min(bucketCount, samples.count)
        var peaks = [Float](repeating: 0, count: usableBuckets)
        let samplesPerBucket = Double(samples.count) / Double(usableBuckets)

        for bucket in 0..<usableBuckets {
            let start = Int(Double(bucket) * samplesPerBucket)
            let end = min(samples.count, Int(Double(bucket + 1) * samplesPerBucket))
            var peak: Float = 0
            for index in start..<max(end, start + 1) where index < samples.count {
                peak = max(peak, abs(samples[index]))
            }
            peaks[bucket] = peak
        }

        let global = peaks.max() ?? 0
        guard global > 0 else { return peaks }
        return peaks.map { $0 / global }
    }
}
