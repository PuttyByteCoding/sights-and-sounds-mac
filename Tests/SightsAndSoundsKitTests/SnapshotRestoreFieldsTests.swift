import Testing

@testable import SightsAndSoundsKit

/// A tag snapshot is raw ffprobe output, and for MP4 ffprobe names tags
/// its own way: `album_artist`, `track`, plus container keys that are
/// not tags at all. Restoring used to write every unknown name back as
/// a freeform atom — album artist became `----:com.apple.iTunes:ALBUM_ARTIST`
/// instead of `aART`, the track number was lost to players, and
/// `MAJOR_BRAND`/`ENCODER` junk atoms were added.
@Suite struct SnapshotRestoreFieldsTests {
    private let mp4Snapshot = """
        {"format": {"tags": {"major_brand": "isom", "minor_version": "512",
          "compatible_brands": "isomiso2mp41", "encoder": "Lavf61.7.100",
          "title": "Opening Night", "album_artist": "The Meadow Larks",
          "track": "3", "creation_time": "2026-01-01T00:00:00.000000Z"}},
         "streams": [{"tags": {"language": "und", "handler_name": "SoundHandler",
          "vendor_id": "[0][0][0][0]"}}]}
        """

    @Test func ffprobeNamesMapToTheirStandardFields() {
        let fields = SnapshotRestore.fields(fromSnapshotJSON: mp4Snapshot)
        let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.vorbisName, $0) })

        #expect(byName["ALBUMARTIST"]?.mp4Atom == "aART")
        #expect(byName["ALBUMARTIST"]?.mp4Freeform == false)
        #expect(byName["ALBUMARTIST"]?.values == ["The Meadow Larks"])
        #expect(byName["TRACKNUMBER"]?.mp4Atom == "trkn")
        #expect(byName["TITLE"]?.values == ["Opening Night"])
    }

    @Test func containerHousekeepingIsNotRestoredAsTags() {
        let names = Set(SnapshotRestore.fields(fromSnapshotJSON: mp4Snapshot).map(\.vorbisName))
        for junk in ["MAJOR_BRAND", "MINOR_VERSION", "COMPATIBLE_BRANDS", "ENCODER",
                     "CREATION_TIME", "LANGUAGE", "HANDLER_NAME", "VENDOR_ID",
                     "ALBUM_ARTIST", "TRACK"] {
            #expect(!names.contains(junk), "\(junk) should not be restored as a tag")
        }
    }

    @Test func anUnknownRealTagStillRoundTripsAsFreeform() {
        let json = #"{"format": {"tags": {"TAPER": "Someone"}}}"#
        let fields = SnapshotRestore.fields(fromSnapshotJSON: json)
        #expect(fields.map(\.vorbisName) == ["TAPER"])
        #expect(fields.first?.mp4Freeform == true)
    }

    /// The preview shows "previous value" by the standard name, so the
    /// ffprobe spelling has to be read under it.
    @Test func thePreviewReadsFfprobeNamesUnderTheStandardName() {
        let existing = WritebackPreview.parseTags(json: mp4Snapshot)
        #expect(existing["albumartist"] == ["The Meadow Larks"])
        #expect(existing["tracknumber"] == ["3"])
    }
}
