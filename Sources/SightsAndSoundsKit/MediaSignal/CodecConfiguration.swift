import Foundation

/// Profile, level, bit depth and chroma layout, read from the decoder
/// configuration record a container carries for its video track (`avcC`
/// for H.264, `hvcC` for HEVC).
///
/// AVFoundation hands the record over as raw bytes and names none of what
/// is in it. The layouts are fixed by ISO/IEC 14496-15, and the few bytes
/// wanted here sit at fixed offsets, so this reads them directly rather
/// than asking an external tool for something already in hand.
public struct CodecConfiguration: Equatable, Sendable {
    public var profile: String
    public var level: String
    /// HEVC only: Main or High tier.
    public var tier: String?
    public var bitDepth: Int?
    /// "4:2:0", "4:2:2", "4:4:4" or "4:0:0".
    public var chromaSubsampling: String?

    static func chromaName(_ format: UInt8) -> String? {
        switch format {
        case 0: "4:0:0"
        case 1: "4:2:0"
        case 2: "4:2:2"
        case 3: "4:4:4"
        default: nil
        }
    }

    // MARK: - H.264

    public static func avc(_ record: Data) -> CodecConfiguration? {
        let bytes = [UInt8](record)
        guard bytes.count >= 6, bytes[0] == 1 else { return nil }
        let profileIDC = bytes[1]
        let constraints = bytes[2]
        let levelIDC = bytes[3]

        let profile: String = switch profileIDC {
        case 66: constraints & 0x40 != 0 ? "Constrained Baseline" : "Baseline"
        case 77: "Main"
        case 88: "Extended"
        case 100: "High"
        case 110: "High 10"
        case 122: "High 4:2:2"
        case 244: "High 4:4:4 Predictive"
        default: "profile \(profileIDC)"
        }
        // Level 1b is the one level that is not its number over ten.
        let level = levelIDC == 11 && constraints & 0x10 != 0
            ? "1b" : formatLevel(Double(levelIDC) / 10)

        var configuration = CodecConfiguration(profile: profile, level: level)

        // The high profiles append chroma format and bit depth after the
        // parameter sets; everything below them is 8-bit 4:2:0 by definition.
        guard [100, 110, 122, 144, 244].contains(profileIDC) else {
            configuration.bitDepth = 8
            configuration.chromaSubsampling = "4:2:0"
            return configuration
        }
        var offset = 5
        let sequenceSets = Int(bytes[offset] & 0x1F)
        offset += 1
        guard skipParameterSets(sequenceSets, in: bytes, at: &offset), offset < bytes.count
        else { return configuration }
        let pictureSets = Int(bytes[offset])
        offset += 1
        guard skipParameterSets(pictureSets, in: bytes, at: &offset), offset + 1 < bytes.count
        else { return configuration }
        configuration.chromaSubsampling = chromaName(bytes[offset] & 0x03)
        configuration.bitDepth = Int(bytes[offset + 1] & 0x07) + 8
        return configuration
    }

    private static func skipParameterSets(_ count: Int, in bytes: [UInt8], at offset: inout Int) -> Bool {
        for _ in 0..<count {
            guard offset + 2 <= bytes.count else { return false }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2 + length
            guard offset <= bytes.count else { return false }
        }
        return true
    }

    // MARK: - HEVC

    public static func hevc(_ record: Data) -> CodecConfiguration? {
        let bytes = [UInt8](record)
        guard bytes.count >= 19, bytes[0] == 1 else { return nil }
        let tierFlag = bytes[1] & 0x20 != 0
        let profileIDC = bytes[1] & 0x1F
        let levelIDC = bytes[12]

        let profile: String = switch profileIDC {
        case 1: "Main"
        case 2: "Main 10"
        case 3: "Main Still Picture"
        case 4: "Range Extensions"
        default: "profile \(profileIDC)"
        }
        return CodecConfiguration(
            profile: profile,
            level: formatLevel(Double(levelIDC) / 30),
            tier: tierFlag ? "High" : "Main",
            bitDepth: Int(bytes[17] & 0x07) + 8,
            chromaSubsampling: chromaName(bytes[16] & 0x03))
    }

    private static func formatLevel(_ level: Double) -> String {
        level == level.rounded() ? String(format: "%.0f", level) : String(format: "%.1f", level)
    }
}

extension CodecConfiguration {
    /// The settings string x264 and x265 write into the stream as user
    /// data, which is where a transcoder says what it did: the library's
    /// version, the rate control mode and its target.
    ///
    /// It is plain text inside the first sample, so it is found by looking
    /// for it rather than by parsing the NAL units around it.
    public static func encoderSettings(inFirstSample sample: Data) -> String? {
        for marker in ["x264 - core", "x265 (build"] {
            guard let start = sample.range(of: Data(marker.utf8))?.lowerBound else { continue }
            let tail = sample[start...].prefix(4096)
            let text = tail.prefix { $0 != 0 }
            guard let string = String(data: Data(text), encoding: .utf8) else { continue }
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
