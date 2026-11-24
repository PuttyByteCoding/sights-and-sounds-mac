import Foundation

/// The cheap duplicate check: what the library already knows about each
/// file — its name, byte size and running time — and nothing read from
/// disk. Pure functions, so the rules can be tested without a library.
///
/// Two ways a pair is proposed:
///
/// - **Similar name.** The names are the same once a copy marker is taken
///   off the end: Finder's "copy" / "copy 2", Windows' "- Copy" /
///   "- Copy (2)", a browser's "(1)", and stray separators left behind.
///   The extension is ignored, so a re-encode (`.avi` → `.mp4`) still
///   pairs. Agreeing size and running time raise the confidence.
/// - **Same size and length.** Different names, the exact same byte
///   count and a running time within a second: a renamed copy.
///
/// A numbered series is not a copy: "Lesson (1)" and "Lesson (2)" both
/// carry a marker, and neither is the unmarked original, so such a pair
/// is proposed only when its size or running time also agrees.
public enum LikelyDuplicateMatcher {
    public struct File: Sendable, Equatable {
        public var id: UUID
        public var fileName: String
        public var fileSize: Int64
        public var durationSeconds: Double?

        public init(id: UUID, fileName: String, fileSize: Int64, durationSeconds: Double?) {
            self.id = id
            self.fileName = fileName
            self.fileSize = fileSize
            self.durationSeconds = durationSeconds
        }
    }

    public struct Pair: Sendable, Equatable {
        public var a: UUID
        public var b: UUID
        public var source: CandidateSource
        public var confidence: Double
    }

    /// A name with its extension and any copy marker taken off, folded
    /// for comparison; and whether a marker was there.
    public struct Stem: Sendable, Equatable {
        public var text: String
        public var hadMarker: Bool
    }

    /// Files smaller than this are never paired on size alone: small
    /// files of one exact size are common (a stock sound, an empty clip).
    public static let minimumSizeForSizeMatch: Int64 = 1_000_000
    /// How far two running times may differ and still be "the same".
    public static let durationTolerance: Double = 1.0

    // MARK: - Names

    /// "Show copy 2.mp4" → ("show", true); "Show.mp4" → ("show", false).
    public static func stem(of fileName: String) -> Stem {
        var name = (fileName as NSString).deletingPathExtension
        var hadMarker = false
        // Markers can stack ("Show (1) copy"), so peel until none is left.
        while true {
            let trimmed = trimSeparators(name)
            if trimmed != name { name = trimmed }
            guard let peeled = peelMarker(name) else { break }
            name = peeled
            hadMarker = true
        }
        let folded = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return Stem(text: folded, hadMarker: hadMarker)
    }

    /// The copy markers, matched at the end of the name, case-insensitive:
    /// " copy", " copy 3", " - copy", " - copy (2)", " (1)", " [2]".
    /// A bare trailing number ("Lesson 2") is NOT a marker: it is how a
    /// series is named.
    private static let markers: [NSRegularExpression] = [
        #"[\s_\-]+copy(\s*\(?\d+\)?)?$"#,
        #"\s*\(\d{1,3}\)$"#,
        #"\s*\[\d{1,3}\]$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func peelMarker(_ name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        for marker in markers {
            if let match = marker.firstMatch(in: name, range: range),
               let found = Range(match.range, in: name),
               found.lowerBound > name.startIndex {
                return String(name[..<found.lowerBound])
            }
        }
        return nil
    }

    /// Stray separators a copy tool leaves at the end: spaces, "_", "-",
    /// ".", and a trailing backslash.
    private static func trimSeparators(_ name: String) -> String {
        var result = Substring(name)
        while let last = result.last, last.isWhitespace || "_-.\\".contains(last) {
            result = result.dropLast()
        }
        return result.isEmpty ? name : String(result)
    }

    // MARK: - Pairs

    static func sameLength(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b, a > 0, b > 0 else { return false }
        return abs(a - b) <= durationTolerance
    }

    /// Within 1% — the same content muxed again, or tagged differently.
    static func nearSize(_ a: Int64, _ b: Int64) -> Bool {
        guard a > 0, b > 0 else { return false }
        return Double(abs(a - b)) / Double(max(a, b)) <= 0.01
    }

    /// How sure a similar-name pair is: the name alone is a hint, the
    /// running time and the size are evidence.
    static func nameConfidence(_ x: File, _ y: File) -> Double {
        var confidence = 0.5
        if sameLength(x.durationSeconds, y.durationSeconds) { confidence += 0.25 }
        if x.fileSize == y.fileSize, x.fileSize > 0 {
            confidence += 0.2
        } else if nearSize(x.fileSize, y.fileSize) {
            confidence += 0.1
        }
        return min(confidence, 0.95)
    }

    /// Every pair worth a look, each once. Name pairs come first: a pair
    /// that matches both ways is reported as a name pair.
    public static func pairs(in files: [File]) -> [Pair] {
        var result: [Pair] = []
        var seen: Set<String> = []
        func key(_ a: UUID, _ b: UUID) -> String {
            a.uuidString <= b.uuidString ? "\(a)|\(b)" : "\(b)|\(a)"
        }

        // Similar names.
        var byStem: [String: [(file: File, marked: Bool)]] = [:]
        for file in files {
            let found = Self.stem(of: file.fileName)
            guard !found.text.isEmpty else { continue }
            byStem[found.text, default: []].append((file, found.hadMarker))
        }
        for group in byStem.values where group.count > 1 {
            // A very large group is a naming scheme, not a set of copies.
            guard group.count <= 20 else { continue }
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    let x = group[i], y = group[j]
                    let sameName = !x.marked && !y.marked
                    let evidence = sameLength(x.file.durationSeconds, y.file.durationSeconds)
                        || nearSize(x.file.fileSize, y.file.fileSize)
                    // One marked beside its original is a copy. Two
                    // marked, or two with the same name in different
                    // folders, need the size or running time to agree.
                    if (x.marked && y.marked) || sameName {
                        guard evidence else { continue }
                    }
                    guard seen.insert(key(x.file.id, y.file.id)).inserted else { continue }
                    result.append(Pair(
                        a: x.file.id, b: y.file.id, source: .similarName,
                        confidence: nameConfidence(x.file, y.file)))
                }
            }
        }

        // Same size and length, any names.
        var bySize: [Int64: [File]] = [:]
        for file in files where file.fileSize >= minimumSizeForSizeMatch {
            bySize[file.fileSize, default: []].append(file)
        }
        for group in bySize.values where group.count > 1 {
            guard group.count <= 20 else { continue }
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    let x = group[i], y = group[j]
                    guard sameLength(x.durationSeconds, y.durationSeconds) else { continue }
                    guard seen.insert(key(x.id, y.id)).inserted else { continue }
                    result.append(Pair(a: x.id, b: y.id, source: .sizeAndLength, confidence: 0.7))
                }
            }
        }
        return result
    }
}
