import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The per-video analysis: every place metadata might live, one engine,
/// three buckets. The scenarios are the taper story the feature exists
/// for.
@Suite struct ItemAnalysisTests {

    private func makeLibrary() async throws -> (LibraryDatabase, Source, TagCategory) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Analysis")
        let source = Source(name: "S", rootPath: "/tmp/analysis")
        let taper = TagCategory(name: "Taper")
        try await library.writer.write { db in
            try source.insert(db)
            try taper.insert(db)
        }
        return (library, source, taper)
    }

    @discardableResult
    private func insertItem(
        _ library: LibraryDatabase, _ source: Source, path: String
    ) async throws -> MediaItem {
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: path, needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return item
    }

    private func rule(_ matcher: RuleMatcher, _ actions: [RuleAction]) -> RuleEngine.Rule {
        RuleEngine.Rule(id: UUID(), matcher: matcher, actions: actions)
    }

    // MARK: - The taper story

    @Test func aCustomMetadataFieldMapsToItsCategory() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [("taper", "Mike Jones")])

        let analysis = try library.analyzeItem(
            item.id,
            rules: [rule(.keyEquals(key: "taper"), [.assignCategory(category: "Taper")])])
        #expect(analysis.suggested.map(\.value) == ["Mike Jones"])
        #expect(analysis.suggested.first?.category == "Taper")
        #expect(analysis.suggested.first?.key == "taper")
    }

    @Test func jsonInsideAMetadataValueYieldsKeyedLeaves() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        // The older-videos case: a JSON string stored in embedded
        // metadata, the key beside the value naming what it is.
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("comment", #"{"taper": "Mike Jones", "venue": "Newport"}"#),
        ])

        let analysis = try library.analyzeItem(
            item.id,
            rules: [rule(.keyEquals(key: "taper"), [.assignCategory(category: "Taper")])])
        // The leaf under "taper" mapped; the one under "venue" did not,
        // but it survived into the unmapped list WITH its key shown.
        #expect(analysis.suggested.map(\.value) == ["Mike Jones"])
        let venue = try #require(analysis.unmapped.first { $0.value == "Newport" })
        #expect(venue.key == "venue")
    }

    @Test func aPrefixRuleStripsAndMapsInOnePass() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("comment", "tapper: Mike Jones"),
        ])

        let analysis = try library.analyzeItem(
            item.id,
            rules: [rule(
                .valueStartsWith(prefix: "tapper: "),
                [.stripPrefix(prefix: "tapper: "), .assignCategory(category: "Taper")])])
        #expect(analysis.suggested.map(\.value) == ["Mike Jones"])
    }

    @Test func theStripRunsOnceNotTwice() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        // A value whose STRIPPED form still starts with the prefix. One
        // fold strips one layer; the keyed entry to the hub must not
        // fold again on the way out.
        try library.recordMetadataPairs(itemID: item.id, pairs: [("comment", "The The Band")])

        let analysis = try library.analyzeItem(
            item.id,
            rules: [rule(.valueStartsWith(prefix: "The "), [.stripPrefix(prefix: "The ")])])
        // (The filename rides along from the path reader, correctly.)
        #expect(analysis.unmapped.map(\.value).contains("The Band"))
        #expect(!analysis.unmapped.map(\.value).contains("Band"))
    }

    @Test func pathSegmentsSurfaceAndHiddenRootsDoNot() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "shows/MikeJones/a.mp4")

        let analysis = try library.analyzeItem(
            item.id,
            rules: [rule(.pathRootStartsWith(root: "shows"), [.hidePrefix])])
        let values = analysis.unmapped.map(\.value)
        // "shows" is the never-useful crap, stripped by the hidePrefix
        // rule before segmentation; the taper's directory survives.
        #expect(values.contains("MikeJones"))
        #expect(!values.contains("shows"))
    }

    @Test func existingTagsAreFoundInsideLongerText() async throws {
        let (library, source, taper) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        let mike = Tag(tagCategoryID: taper.id, name: "Mike Jones")
        try await library.writer.write { try mike.insert($0) }
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("comment", "taped by Mike Jones 2019"),
        ])

        let analysis = try library.analyzeItem(item.id, rules: [])
        let finding = try #require(analysis.existing.first)
        #expect(finding.tag.id == mike.id)
        #expect(finding.categoryName == "Taper")
        #expect(finding.foundIn == "taped by Mike Jones 2019")
        #expect(!finding.alreadyApplied)
        // The raw text also stays in the unmapped list — the finding
        // points INTO it, not instead of it.
        #expect(analysis.unmapped.map(\.value).contains("taped by Mike Jones 2019"))
    }

    @Test func wordBoundariesStopFalseHits() async throws {
        let (library, source, taper) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try await library.writer.write {
            try Tag(tagCategoryID: taper.id, name: "Jones").insert($0)
        }
        try library.recordMetadataPairs(itemID: item.id, pairs: [("comment", "Jonestown 1978")])

        let analysis = try library.analyzeItem(item.id, rules: [])
        #expect(analysis.existing.isEmpty)
    }

    @Test func aliasesFindTheirTagAndCollisionsListEveryCategory() async throws {
        let (library, source, taper) = try await makeLibrary()
        let band = TagCategory(name: "Band")
        let item = try await insertItem(library, source, path: "a.mp4")
        let taperTag = Tag(tagCategoryID: taper.id, name: "Mike Jones")
        let bandTag = Tag(tagCategoryID: band.id, name: "Mike Jones")
        try await library.writer.write { db in
            try band.insert(db)
            try taperTag.insert(db)
            try bandTag.insert(db)
            try TagAlias(tagID: taperTag.id, alias: "MJones").insert(db)
        }
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("a", "recorded by MJones"),
            ("b", "Mike Jones live"),
        ])

        let analysis = try library.analyzeItem(item.id, rules: [])
        // The alias found its tag…
        #expect(analysis.existing.contains { $0.matchedText == "MJones" && $0.tag.id == taperTag.id })
        // …and the name living in TWO categories produced two findings —
        // the collision is shown, and the manual path decides.
        let mikeHits = analysis.existing.filter { $0.foundIn == "Mike Jones live" }
        #expect(Set(mikeHits.map(\.categoryName)) == ["Taper", "Band"])
    }

    @Test func ignoreRulesSuppressTagMatchingButKeepTheText() async throws {
        let (library, source, taper) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try await library.writer.write {
            try Tag(tagCategoryID: taper.id, name: "Lavf58").insert($0)
        }
        try library.recordMetadataPairs(itemID: item.id, pairs: [("encoder", "Lavf58")])

        let analysis = try library.analyzeItem(
            item.id, rules: [rule(.keyEquals(key: "encoder"), [.ignore])])
        // No existing-tag finding — that is the false-positive reduction —
        // but the text is still listed, struck.
        #expect(analysis.existing.isEmpty)
        let struck = try #require(analysis.unmapped.first)
        #expect(struck.suppressedByRule == "key \"encoder\"")
    }

    @Test func anAppliedTagIsMarkedNotHidden() async throws {
        let (library, source, taper) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        let mike = Tag(tagCategoryID: taper.id, name: "Mike Jones")
        try await library.writer.write { try mike.insert($0) }
        try library.assignTag(mike.id, to: item.id)
        try library.recordMetadataPairs(itemID: item.id, pairs: [("taper", "Mike Jones")])

        let analysis = try library.analyzeItem(item.id, rules: [])
        #expect(analysis.existing.first?.alreadyApplied == true)
    }

    @Test func originsMergeWhenTwoReadersFindTheSameString() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "MikeJones/a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [("taper", "MikeJones")])

        let analysis = try library.analyzeItem(item.id, rules: [])
        // Metadata says MikeJones under "taper"; the path says MikeJones
        // unkeyed. Different keys, so two rows — each true to where it
        // was found. (Same key + same text merges; the seen-set inside
        // one source already proves that.)
        let rows = analysis.unmapped.filter { $0.value == "MikeJones" }
        #expect(rows.count == 2)
        #expect(Set(rows.compactMap(\.key)) == ["taper"])
    }

    // MARK: - The basket

    @Test func commitCreatesAppliesAndReusesByName() async throws {
        let (library, source, taper) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        let existing = Tag(tagCategoryID: taper.id, name: "Old Hand")
        try await library.writer.write { try existing.insert($0) }

        let applied = try library.commitPendingTags([
            PendingTag(value: "Mike Jones", categoryID: taper.id),
            PendingTag(value: "ignored text", categoryID: taper.id, existingTagID: existing.id),
            PendingTag(value: "   ", categoryID: taper.id),  // judged, then emptied — skipped
        ], to: item.id)

        #expect(applied == 2)
        let names = Set(try library.tags(of: item.id).flatMap(\.tags).map(\.name))
        #expect(names == ["Mike Jones", "Old Hand"])

        // Committing the same value again applies the SAME tag — no dupe.
        _ = try library.commitPendingTags(
            [PendingTag(value: "mike jones", categoryID: taper.id)], to: item.id)
        let all = try await library.writer.read { try Tag.fetchAll($0) }
        #expect(all.count { $0.name.lowercased() == "mike jones" } == 1)
    }

    @Test func aTruncatedRunSaysSo() async throws {
        let (library, source, _) = try await makeLibrary()
        let item = try await insertItem(library, source, path: "a.mp4")
        try library.recordMetadataPairs(itemID: item.id, pairs: [("a", "b")])

        let analysis = try library.analyzeItem(item.id, rules: [], deadline: .expired)
        #expect(analysis.truncated)
    }
}

/// The sidecar readers, against a real temp folder.
@Suite struct SidecarReaderTests {

    private func makeLibraryOnDisk() async throws -> (LibraryDatabase, Source, TagCategory, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sas-sidecars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Sidecars")
        let source = Source(name: "S", rootPath: root.path)
        let taper = TagCategory(name: "Taper")
        try await library.writer.write { db in
            try source.insert(db)
            try taper.insert(db)
        }
        return (library, source, taper, root)
    }

    @Test func onlyTheVideosOwnSidecarsFeedTheAnalysis() async throws {
        let (library, source, _, root) = try await makeLibraryOnDisk()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("show", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("a.mp4").path, contents: Data())
        // The video's OWN sidecars — same basename.
        try "Recorded at Newport\ntapper: Mike Jones\n\n".write(
            to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try #"{"taper": "Sarah Chen"}"#.write(
            to: folder.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
        // A NEIGHBOUR's sidecars, in the same folder. Their content must
        // not appear: the analysis is per video, and a mixed folder made
        // every loose file everyone's evidence — the reported bug.
        try "tapper: Somebody Else".write(
            to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "Recorded elsewhere".write(
            to: folder.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)

        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "show/a.mp4", needsReview: false)
        try await library.writer.write { try item.insert($0) }

        let analysis = try library.analyzeItem(
            item.id,
            rules: [
                RuleEngine.Rule(
                    id: UUID(), matcher: .keyEquals(key: "taper"),
                    actions: [.assignCategory(category: "Taper")]),
                RuleEngine.Rule(
                    id: UUID(), matcher: .valueStartsWith(prefix: "tapper: "),
                    actions: [
                        .stripPrefix(prefix: "tapper: "),
                        .assignCategory(category: "Taper"),
                    ]),
            ])

        // Own sidecars feed both routes into Suggested…
        #expect(Set(analysis.suggested.map(\.value)) == ["Mike Jones", "Sarah Chen"])
        #expect(analysis.unmapped.map(\.value).contains("Recorded at Newport"))
        // …and the neighbours' content is nowhere on the page.
        let everything = (analysis.suggested + analysis.unmapped).map(\.value)
        #expect(!everything.contains("Somebody Else"))
        #expect(!everything.contains("Recorded elsewhere"))
    }

    @Test func anOversizedSidecarIsSkippedNotTruncated() async throws {
        let (library, source, _, root) = try await makeLibraryOnDisk()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("a.mp4").path, contents: Data())
        // Over the cap: skipped whole — half a document parses as noise.
        let big = String(repeating: "x", count: SidecarFiles.maxBytes + 1)
        try big.write(
            to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { try item.insert($0) }

        let analysis = try library.analyzeItem(item.id, rules: [])
        #expect(!analysis.unmapped.contains { $0.value.hasPrefix("xxx") })
        #expect(!analysis.truncated)
    }

    @Test func anOfflineSourceDegradesToNoSidecarsNotAnError() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Offline")
        let source = Source(name: "S", rootPath: "/nonexistent/\(UUID().uuidString)")
        try await library.writer.write { try source.insert($0) }
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "show/a.mp4", needsReview: false)
        try await library.writer.write { try item.insert($0) }
        try library.recordMetadataPairs(itemID: item.id, pairs: [("taper", "Mike Jones")])

        // The stored evidence still analyses; the disk half is just absent.
        let analysis = try library.analyzeItem(item.id, rules: [])
        #expect(analysis.unmapped.contains { $0.value == "Mike Jones" })
    }
}
