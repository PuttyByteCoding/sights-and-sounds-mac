import Foundation
import GRDB

/// What a demo seed produced — counts for display and assertion.
public struct DemoSeedReport: Sendable {
    public var shows = 0
    public var videoItems = 0
    public var audioItems = 0
    public var taggings = 0
    public var fieldValues = 0
}

/// Fills a library with a plausible fake concert collection: the Concerts
/// template vocabulary, invented bands/venues/years, show folders holding
/// several files each, taggings, field values, and a scattering of flags.
///
/// Deterministic for a given seed. Optionally calls back per item so a
/// caller (the app's demo flow) can synthesize a real media file at the
/// item's path before the row is written.
public enum DemoLibrarySeeder {
    @discardableResult
    public static func seed(
        library: LibraryDatabase,
        source: Source,
        showCount: Int = 18,
        audioShowCount: Int = 4,
        seed: UInt64 = 1,
        makeFile: (@Sendable (_ relativePath: String, _ kind: MediaKind) async throws -> Int64?)? = nil
    ) async throws -> DemoSeedReport {
        var rng = DemoVocabulary.SeededGenerator(seed: seed)
        var report = DemoSeedReport()

        // Vocabulary via the same plan the app's creation flow writes.
        let plan = LibraryTemplate.concerts.plan(named: (try library.info()?.name) ?? "Demo")
        try await library.writer.write { db in try source.insert(db) }
        _ = try writePlan(plan, into: library)

        // Look the created rows back up by name.
        let (categories, tagsByCategory, fieldsByName) = try vocabulary(of: library)
        guard
            let bandCategory = categories["Band"],
            let recTypeCategory = categories["Recording Type"],
            let venueCategory = categories["Venue"],
            let yearCategory = categories["Year"]
        else { throw DatabaseError(message: "concerts template shape changed") }

        // Bands, venues and years become tags up front.
        let bandTags = DemoVocabulary.bands.enumerated().map { index, name in
            Tag(tagCategoryID: bandCategory.id, name: name, sortOrder: index)
        }
        let venueTags = DemoVocabulary.venues.enumerated().map { index, name in
            Tag(tagCategoryID: venueCategory.id, name: name, sortOrder: index)
        }
        let yearTags: [UUID: Tag] = [:]  // pre-existing year tags (none on a fresh seed)
        try await library.writer.write { db in
            for tag in bandTags + venueTags { try tag.insert(db) }
        }
        let recTypeTags = tagsByCategory[recTypeCategory.id] ?? []

        // Pass 1 — PLAN: every RNG decision, in the exact order the
        // single-pass version made them, so a given seed still produces an
        // identical library.
        struct PlannedFile {
            let item: MediaItem
            let tagIDs: [UUID]
            let showDate: String
            let setlistNote: String?
            let generateReal: Bool
        }
        var newYearTags: [Tag] = []
        var planned: [PlannedFile] = []
        let totalShows = showCount + audioShowCount

        for showIndex in 0..<totalShows {
            let isAudio = showIndex >= showCount
            let band = bandTags[Int(rng.next() % UInt64(bandTags.count))]
            let venue = venueTags[Int(rng.next() % UInt64(venueTags.count))]
            let recType = recTypeTags[Int(rng.next() % UInt64(max(recTypeTags.count, 1)))]
            let year = 1988 + Int(rng.next() % 16)
            let month = 1 + Int(rng.next() % 12)
            let day = 1 + Int(rng.next() % 28)
            let date = String(format: "%04d-%02d-%02d", year, month, day)

            let yearTag: Tag
            if let existing = (yearTags.values + newYearTags).first(where: { $0.name == String(year) }) {
                yearTag = existing
            } else {
                let tag = Tag(tagCategoryID: yearCategory.id, name: String(year))
                newYearTags.append(tag)
                yearTag = tag
            }

            let folder = (isAudio ? "audio/" : "shows/") + "\(year)/\(date) \(band.name)"
            let fileCount = 2 + Int(rng.next() % 3)
            report.shows += 1

            for fileIndex in 1...fileCount {
                let ext = isAudio ? "m4a" : "mp4"
                let path = "\(folder)/d1t\(String(format: "%02d", fileIndex)).\(ext)"
                let generateReal = makeFile != nil
                let sizeFallback = Int64(20_000_000 + rng.next() % 500_000_000)
                let durationFallback = Double(180 + rng.next() % 3_400)

                var item = MediaItem(
                    sourceID: source.id,
                    kind: isAudio ? .audio : .video,
                    relativePath: path,
                    fileSize: sizeFallback,
                    durationSeconds: generateReal ? nil : durationFallback,
                    width: isAudio ? nil : 1280,
                    height: isAudio ? nil : 720,
                    videoCodec: isAudio ? nil : "h264",
                    audioCodec: isAudio ? "aac" : "aac",
                    needsReview: rng.next() % 8 == 0)
                item.isFavorite = rng.next() % 7 == 0
                item.watchCount = Int(rng.next() % 4)

                let note: String?
                if fileIndex == 1 {
                    note = DemoVocabulary.setlistNotes[Int(rng.next() % UInt64(DemoVocabulary.setlistNotes.count))]
                } else {
                    note = nil
                }
                planned.append(PlannedFile(
                    item: item,
                    tagIDs: [band.id, recType.id, yearTag.id, venue.id],
                    showDate: date,
                    setlistNote: note,
                    generateReal: generateReal))
            }
        }

        // Pass 2 — GENERATE: file synthesis awaits outside any transaction.
        var sizes: [String: Int64] = [:]
        if let makeFile {
            for file in planned {
                if let size = try await makeFile(file.item.relativePath, file.item.kind) {
                    sizes[file.item.relativePath] = size
                }
            }
        }

        // Pass 3 — INSERT: one write transaction. (Counting happens outside
        // the Sendable closure.)
        let fields = fieldsByName
        let finalSizes = sizes
        let toInsert = planned.map { file -> PlannedFile in
            var updated = file
            if let size = finalSizes[file.item.relativePath] {
                var item = file.item
                item.fileSize = size
                updated = PlannedFile(
                    item: item, tagIDs: file.tagIDs, showDate: file.showDate,
                    setlistNote: file.setlistNote, generateReal: file.generateReal)
            }
            return updated
        }
        let yearTagsToInsert = newYearTags
        try await library.writer.write { db in
            for tag in yearTagsToInsert { try tag.insert(db) }
            for file in toInsert {
                try file.item.insert(db)
                for tagID in file.tagIDs {
                    try MediaItemTag(mediaItemID: file.item.id, tagID: tagID).insert(db)
                }
                if let showDate = fields["Show Date"] {
                    try MediaItemFieldValue(
                        mediaItemID: file.item.id, definition: showDate, value: file.showDate).insert(db)
                }
                if let note = file.setlistNote, let notes = fields["Setlist Notes"] {
                    try MediaItemFieldValue(
                        mediaItemID: file.item.id, definition: notes, value: note).insert(db)
                }
            }
        }
        for file in toInsert {
            if file.item.kind == .audio { report.audioItems += 1 } else { report.videoItems += 1 }
            report.taggings += file.tagIDs.count
            if fields["Show Date"] != nil { report.fieldValues += 1 }
            if file.setlistNote != nil, fields["Setlist Notes"] != nil { report.fieldValues += 1 }
        }
        return report
    }

    // MARK: - Helpers

    /// Write a plan's vocabulary (shared with LibraryCreator's inner loop —
    /// duplicated minimally here to keep the creator's file-creation
    /// semantics untouched; revisit if a third caller appears).
    private static func writePlan(_ plan: LibraryPlan, into library: LibraryDatabase) throws -> Int {
        var written = 0
        try library.writer.write { db in
            for planned in plan.categories where planned.include {
                let category = TagCategory(
                    name: planned.name, allowMultiple: planned.allowMultiple,
                    displayAsCheckboxes: planned.displayAsCheckboxes,
                    sortOrder: planned.sortOrder, notes: planned.notes,
                    sectionLabel: planned.sectionLabel,
                    isDefaultFocus: planned.isDefaultFocus,
                    textFormat: planned.textFormat,
                    separatorsToSpaces: planned.separatorsToSpaces,
                    writebackEnabled: planned.writebackEnabled,
                    writebackField: planned.writebackField)
                try category.insert(db)
                written += 1
                for plannedTag in planned.tags {
                    let tag = Tag(
                        tagCategoryID: category.id, name: plannedTag.name,
                        isFavorite: plannedTag.isFavorite, sortOrder: plannedTag.sortOrder,
                        notes: plannedTag.notes)
                    try tag.insert(db)
                    for alias in plannedTag.aliases {
                        try TagAlias(tagID: tag.id, alias: alias).insert(db)
                    }
                }
                for field in planned.fields {
                    try FieldDefinition(
                        name: field.name, dataType: field.dataType, scope: .tag,
                        tagCategoryID: category.id, sortOrder: field.sortOrder).insert(db)
                }
            }
            for field in plan.itemFields where field.include {
                try FieldDefinition(
                    name: field.name, dataType: field.dataType, scope: .mediaItem,
                    sortOrder: field.sortOrder, notes: field.notes).insert(db)
            }
        }
        return written
    }

    private static func vocabulary(of library: LibraryDatabase) throws
        -> (categories: [String: TagCategory], tagsByCategory: [UUID: [Tag]], fieldsByName: [String: FieldDefinition])
    {
        try library.writer.read { db in
            let categories = Dictionary(
                uniqueKeysWithValues: try TagCategory.fetchAll(db).map { ($0.name, $0) })
            let tagsByCategory = Dictionary(
                grouping: try Tag.order(sql: "sortOrder, name").fetchAll(db), by: \.tagCategoryID)
            let fields = Dictionary(
                uniqueKeysWithValues: try FieldDefinition.fetchAll(db).map { ($0.name, $0) })
            return (categories, tagsByCategory, fields)
        }
    }
}
