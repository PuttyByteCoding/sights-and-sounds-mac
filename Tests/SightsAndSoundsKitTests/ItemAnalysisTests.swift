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

/// Authored JSON schemas: recognition and key mapping.
@Suite struct JsonSchemaTests {

    private func makeLibrary() async throws -> (LibraryDatabase, Source) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Schemas")
        let source = Source(name: "S", rootPath: "/tmp/schemas")
        try await library.writer.write { db in
            try source.insert(db)
            try TagCategory(name: "Taper").insert(db)
            try TagCategory(name: "Venue").insert(db)
        }
        return (library, source)
    }

    @Test func aMatchedSchemaMapsItsKeysIntoSuggested() async throws {
        let (library, source) = try await makeLibrary()
        try library.saveJsonSchema(named: "ShowNotes", keys: [
            SchemaKey(key: "taper", required: true, category: "Taper"),
            SchemaKey(key: "venue", required: true, category: "Venue"),
            SchemaKey(key: "notes", required: false),
        ])
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { try item.insert($0) }
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("comment", #"{"taper": "Mike Jones", "venue": "Newport", "notes": "great set"}"#),
        ])

        let analysis = try library.analyzeItem(item.id, rules: [])
        #expect(analysis.matchedSchemas == ["ShowNotes"])
        let taper = try #require(analysis.suggested.first { $0.value == "Mike Jones" })
        #expect(taper.category == "Taper")
        #expect(taper.mappedBySchema == "ShowNotes")
        #expect(analysis.suggested.contains { $0.value == "Newport" && $0.category == "Venue" })
        // The unmapped optional key's value survives as judgment material.
        #expect(analysis.unmapped.contains { $0.value == "great set" })
    }

    @Test func aPayloadMissingARequiredKeyDoesNotMatch() async throws {
        let (library, source) = try await makeLibrary()
        try library.saveJsonSchema(named: "ShowNotes", keys: [
            SchemaKey(key: "taper", required: true, category: "Taper"),
            SchemaKey(key: "venue", required: true, category: "Venue"),
        ])
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { try item.insert($0) }
        // taper alone — venue is required and absent.
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("comment", #"{"taper": "Mike Jones"}"#),
        ])

        let analysis = try library.analyzeItem(item.id, rules: [])
        #expect(analysis.matchedSchemas.isEmpty)
        #expect(analysis.suggested.isEmpty)
        #expect(analysis.unmapped.contains { $0.value == "Mike Jones" })
    }

    @Test func keysMatchThroughTheEnginesOneFold() async throws {
        let (library, source) = try await makeLibrary()
        try library.saveJsonSchema(named: "ShowNotes", keys: [
            SchemaKey(key: "Taper", required: true, category: "Taper"),
        ])
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { try item.insert($0) }
        // Lowercase in the payload, TitleCase in the schema — the same
        // fold keyEquals uses says they are one key.
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("comment", #"{"taper": "Mike Jones"}"#),
        ])

        let analysis = try library.analyzeItem(item.id, rules: [])
        #expect(analysis.matchedSchemas == ["ShowNotes"])
        #expect(analysis.suggested.first?.category == "Taper")
    }

    @Test func aRulesMappingBeatsTheSchemas() async throws {
        let (library, source) = try await makeLibrary()
        try library.saveJsonSchema(named: "ShowNotes", keys: [
            SchemaKey(key: "taper", required: true, category: "Venue"),  // wrong on purpose
        ])
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { try item.insert($0) }
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("comment", #"{"taper": "Mike Jones"}"#),
        ])

        let analysis = try library.analyzeItem(
            item.id,
            rules: [RuleEngine.Rule(
                id: UUID(), matcher: .keyEquals(key: "taper"),
                actions: [.assignCategory(category: "Taper")])])
        let taper = try #require(analysis.suggested.first { $0.value == "Mike Jones" })
        // Rules are the sharper instrument; the schema is the net.
        #expect(taper.category == "Taper")
        #expect(taper.mappedBySchema == nil)
    }

    @Test func savingTheSameNameReplaces() async throws {
        let (library, _) = try await makeLibrary()
        let first = try library.saveJsonSchema(named: "Notes", keys: [SchemaKey(key: "a")])
        let second = try library.saveJsonSchema(named: "notes", keys: [SchemaKey(key: "b")])
        #expect(second.id == first.id)
        let all = try library.jsonSchemas()
        #expect(all.count == 1)
        #expect(all.first?.keys.map(\.key) == ["b"])
    }
}

/// JSON buried in prose — the reported miss — and the road back.
@Suite struct EmbeddedJsonTests {

    private func makeLibrary() async throws -> (LibraryDatabase, MediaItem) {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Embedded")
        let source = Source(name: "S", rootPath: "/tmp/embedded")
        try await library.writer.write { db in
            try source.insert(db)
            try TagCategory(name: "Taper").insert(db)
        }
        let item = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "a.mp4", needsReview: false)
        try await library.writer.write { try item.insert($0) }
        return (library, item)
    }

    @Test func jsonInsideALongerCommentIsFoundAndKeyed() async throws {
        let (library, item) = try await makeLibrary()
        // The reported case verbatim in shape: prose, then JSON, then
        // prose — the strict starts-with detector never saw it.
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("comment", #"Ripped by X {"taper": "Mike Jones"} enjoy the show"#),
        ])

        let analysis = try library.analyzeItem(
            item.id,
            rules: [RuleEngine.Rule(
                id: UUID(), matcher: .keyEquals(key: "taper"),
                actions: [.assignCategory(category: "Taper")])])
        let taper = try #require(analysis.suggested.first { $0.value == "Mike Jones" })
        #expect(taper.key == "taper")
        // The prose around the span survives, still under the field's
        // own key, so rules on "comment" still see it.
        #expect(analysis.unmapped.contains { $0.value == "Ripped by X" && $0.key == "comment" })
        #expect(analysis.unmapped.contains { $0.value == "enjoy the show" })
    }

    @Test func embeddedSpansIgnoreStrayBracesInProse() async throws {
        let spans = JsonLeafExtractor.embeddedSpans(
            in: #"a {not json} b {"k": "v"} c"#)
        #expect(spans.count == 1)
        #expect(spans.first?.json == #"{"k": "v"}"#)
        // Braces inside JSON strings do not break the balance.
        let tricky = JsonLeafExtractor.embeddedSpans(
            in: #"x {"a": "{brace} in string"} y"#)
        #expect(tricky.count == 1)
    }

    @Test func theTrailSaysTheWholeRoadBack() async throws {
        let (library, item) = try await makeLibrary()
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("comment", #"notes {"taper": "Mike Jones"}"#),
        ])

        let analysis = try library.analyzeItem(item.id, rules: [])
        let taper = try #require(
            (analysis.suggested + analysis.unmapped).first { $0.value == "Mike Jones" })
        // Reader label first, then the parser step — back to the source.
        #expect(taper.trail == ["Embedded metadata · comment", "jsonParser"])
    }
}

extension EmbeddedJsonTests {
    @Test func anEmbeddedPayloadStillMatchesSchemas() async throws {
        let (library, item) = try await makeLibrary()
        try library.saveJsonSchema(named: "ShowNotes", keys: [
            SchemaKey(key: "taper", required: true, category: "Taper"),
        ])
        try library.recordMetadataPairs(itemID: item.id, pairs: [
            ("comment", #"see notes {"taper": "Mike Jones"} end"#),
        ])

        let analysis = try library.analyzeItem(item.id, rules: [])
        #expect(analysis.matchedSchemas == ["ShowNotes"])
        #expect(analysis.suggested.first { $0.value == "Mike Jones" }?.mappedBySchema == "ShowNotes")
    }
}
