import Foundation

/// Turning a tag snapshot (raw ffprobe output) back into fields to write.
///
/// ffprobe names tags its own way, and for MP4 that is not the Vorbis
/// spelling the standard fields use: `album_artist`, `track`. It also
/// reports container housekeeping that is not a tag at all. Matching
/// only the Vorbis names wrote every other name back as a freeform atom
/// — album artist became `----:com.apple.iTunes:ALBUM_ARTIST` instead of
/// `aART`, the track number was lost to players, and `MAJOR_BRAND` /
/// `ENCODER` junk atoms were added.
public enum SnapshotRestore {
    /// ffprobe's names for standard fields, where they differ.
    static let aliases: [String: String] = [
        "album_artist": "ALBUMARTIST",
        "track": "TRACKNUMBER",
        "year": "DATE",
    ]

    /// Written by the container or the muxer, never by a person: not
    /// restored, since the write tools set their own.
    static let housekeeping: Set<String> = [
        "major_brand", "minor_version", "compatible_brands", "encoder", "software",
        "creation_time", "handler_name", "vendor_id", "language", "duration",
        "encoded_by", "timecode",
    ]

    /// The standard field a snapshot tag name stands for, if any.
    static func standardField(named name: String) -> StandardField? {
        let lowered = name.lowercased()
        let key = aliases[lowered] ?? lowered
        return StandardFields.all.first { $0.vorbisName.caseInsensitiveCompare(key) == .orderedSame }
    }

    static func isHousekeeping(_ name: String) -> Bool {
        housekeeping.contains(name.lowercased())
    }

    public static func fields(fromSnapshotJSON json: String) -> [FieldWrite] {
        TagWriters.tagPairs(fromSnapshotJSON: json).compactMap { pair in
            guard !isHousekeeping(pair.name) else { return nil }
            if let standard = standardField(named: pair.name) {
                return FieldWrite(
                    vorbisName: standard.vorbisName, mp4Atom: standard.mp4Atom,
                    mp4Freeform: standard.mp4Freeform, values: [pair.value])
            }
            return FieldWrite(
                vorbisName: pair.name.uppercased(), mp4Atom: pair.name.uppercased(),
                mp4Freeform: true, values: [pair.value])
        }
    }
}
