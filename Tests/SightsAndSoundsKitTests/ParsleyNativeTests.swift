import Foundation
import Testing

@testable import SightsAndSoundsKit

/// Which AtomicParsley flag a restored tag goes back through. A native
/// atom is used only for a value it can hold: AtomicParsley stores text
/// in a number atom as 0 (or wraps it) and still exits 0, so the tag was
/// lost under a success. Anything else stays a custom atom, value intact.
@Suite struct ParsleyNativeTests {
    @Test func numberAtomsTakeOnlyNumbersTheyCanHold() {
        #expect(TagWriters.parsleyNative(name: "disc", value: "1/2") == ["--disk", "1/2"])
        #expect(TagWriters.parsleyNative(name: "track", value: "7") == ["--tracknum", "7"])
        for (name, value) in [("disc", "Disc 2"), ("track", "Silverstone"), ("track", "1; 2"),
                              ("track", "70000"), ("disc", "1/2/3"), ("media_type", "300"),
                              ("media_type", "-1"), ("season_number", "abc"), ("episode_sort", "x")] {
            #expect(TagWriters.parsleyNative(name: name, value: value) == nil, "\(name)=\(value)")
        }
        #expect(TagWriters.parsleyNative(name: "media_type", value: "9") == ["--stik", "value=9"])
    }

    /// Season and episode numbers, sort orders, category, purchase date
    /// and the podcast flag have native atoms too. A restore wrote them as
    /// custom atoms after --metaEnema had wiped the originals, so TV and
    /// Music lost them.
    @Test func moreNativeAtomsGoBackNatively() {
        #expect(TagWriters.parsleyNative(name: "season_number", value: "2") == ["--TVSeasonNum", "2"])
        #expect(TagWriters.parsleyNative(name: "episode_sort", value: "5") == ["--TVEpisodeNum", "5"])
        #expect(TagWriters.parsleyNative(name: "sort_artist", value: "Examples, The")
                == ["--sortOrder", "artist", "Examples, The"])
        #expect(TagWriters.parsleyNative(name: "sort_album_artist", value: "x") == ["--sortOrder", "albumartist", "x"])
        #expect(TagWriters.parsleyNative(name: "category", value: "Talks") == ["--category", "Talks"])
        #expect(TagWriters.parsleyNative(name: "purchase_date", value: "2026-01-02T00:00:00Z")
                == ["--purchaseDate", "2026-01-02T00:00:00Z"])
        #expect(TagWriters.parsleyNative(name: "podcast", value: "1") == ["--podcastFlag", "true"])
        // No safe mapping: stays custom.
        #expect(TagWriters.parsleyNative(name: "rating", value: "4") == nil)
    }

    /// The standard track field goes through `--tracknum` too, and text
    /// there was stored as 0. It is kept as a custom atom instead.
    @Test func aStandardTrackNumberThatIsNotANumberIsKept() {
        #expect(TagWriters.parsleyArguments(forStandard: "trkn", name: "TRACKNUMBER", value: "B-side")
                == ["--rDNSatom", "B-side", "name=TRACKNUMBER", "domain=com.apple.iTunes"])
        #expect(TagWriters.parsleyArguments(forStandard: "trkn", name: "TRACKNUMBER", value: "3/12")
                == ["--tracknum", "3/12"])
        #expect(TagWriters.parsleyArguments(forStandard: "©nam", name: "TITLE", value: "Night One")
                == ["--title", "Night One"])
    }
}
