import Foundation

/// Invented, family-neutral vocabulary for demo libraries and richer test
/// fixtures. Nothing here derives from any real library — bands, venues
/// and tapers are fabrications.
public enum DemoVocabulary {
    public static let bands = [
        "Meadow Larks", "The Copper Foxes", "Static Garden", "Nine Mile Drift",
        "The Salt Flat Five", "Harbor Lights Trio", "Velvet Antenna",
        "The Paper Suns", "Iron Creek Revival", "Glass Balloon",
    ]

    public static let venues = [
        "Riverbend Amphitheater", "The Orpheum", "Cedar Hall",
        "Lakeside Pavilion", "The Blue Room", "Fairgrounds Main Stage",
    ]

    public static let recordingTypes = ["Soundboard", "Audience", "FM Broadcast", "Pro-shot", "Matrix"]

    public static let setlistNotes = [
        "Full show, one cut between sets.",
        "Encore incomplete — deck flipped late.",
        "Upgrade over the previous circulating copy.",
        "First set only.",
        "Patched from the balcony source at 41:20.",
    ]

    /// Deterministic RNG (SplitMix64) so the same seed always builds the
    /// same demo library — tests can assert on contents.
    public struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        public init(seed: UInt64) { state = seed }
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
