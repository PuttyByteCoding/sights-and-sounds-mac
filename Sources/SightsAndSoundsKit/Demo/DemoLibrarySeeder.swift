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
        makeFile: ((_ relativePath: String, _ kind: MediaKind) throws -> Int64?)? = nil
    ) throws -> DemoSeedReport {
        var rng = DemoVocabulary.SeededGenerator(seed: seed)
        var report = DemoSeedReport()

        // Vocabulary via the same plan the app's creation flow writes.
        let plan = LibraryTemplate.concerts.plan(named: (try library.info()?.name) ?? "Demo")
        try library.writer.write { db in try source.insert(db) }
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
        var bandTags: [Tag] = []
        var venueTags: [Tag] = []
        var yearTags: [UUID: Tag] = [:]  // keyed by year value
        try library.writer.write { db in
            for (index, name) in DemoVocabulary.bands.enumerated() {
                let tag = Tag(tagCategoryID: bandCategory.id, name: name, sortOrder: index)
                try tag.insert(db)
                bandTags.append(tag)
            }
            for (index, name) in DemoVocabulary.venues.enumerated() {
                let tag = Tag(tagCategoryID: venueCategory.id, name: name, sortOrder: index)
                try tag.insert(db)
                venueTags.append(tag)
            }
        }
        let recTypeTags = tagsByCategory[recTypeCategory.id] ?? []

        // Shows: a dated folder per show, several files inside.
        let totalShows = showCount + audioShowCount
        try library.writer.write { db in
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
                if let existing = yearTags.values.first(where: { $0.name == String(year) }) {
                    yearTag = existing
                } else {
                    let tag = Tag(tagCategoryID: yearCategory.id, name: String(year))
                    try tag.insert(db)
                    yearTags[tag.id] = tag
                    yearTag = tag
                }

                let folder = (isAudio ? "audio/" : "shows/") + "\(year)/\(date) \(band.name)"
                let fileCount = 2 + Int(rng.next() % 3)
                report.shows += 1

                for fileIndex in 1...fileCount {
                    let ext = isAudio ? "m4a" : "mp4"
                    let path = "\(folder)/d1t\(String(format: "%02d", fileIndex)).\(ext)"
                    let fileSize = try makeFile?(path, isAudio ? .audio : .video)

                    var item = MediaItem(
                        sourceID: source.id,
                        kind: isAudio ? .audio : .video,
                        relativePath: path,
                        fileSize: fileSize ?? Int64(20_000_000 + rng.next() % 500_000_000),
                        durationSeconds: fileSize != nil ? nil : Double(180 + rng.next() % 3_400),
                        width: isAudio ? nil : 1280,
                        height: isAudio ? nil : 720,
                        videoCodec: isAudio ? nil : "h264",
                        audioCodec: isAudio ? "aac" : "aac",
                        needsReview: rng.next() % 8 == 0)
                    item.isFavorite = rng.next() % 7 == 0
                    item.watchCount = Int(rng.next() % 4)
                    try item.insert(db)
                    if isAudio { report.audioItems += 1 } else { report.videoItems += 1 }

                    for tag in [band, recType, yearTag] {
                        try MediaItemTag(mediaItemID: item.id, tagID: tag.id).insert(db)
                        report.taggings += 1
                    }
                    try MediaItemTag(mediaItemID: item.id, tagID: venue.id).insert(db)
                    report.taggings += 1

                    if let showDate = fieldsByName["Show Date"] {
                        try MediaItemFieldValue(mediaItemID: item.id, definition: showDate, value: date).insert(db)
                        report.fieldValues += 1
                    }
                    if fileIndex == 1, let notes = fieldsByName["Setlist Notes"] {
                        let note = DemoVocabulary.setlistNotes[Int(rng.next() % UInt64(DemoVocabulary.setlistNotes.count))]
                        try MediaItemFieldValue(mediaItemID: item.id, definition: notes, value: note).insert(db)
                        report.fieldValues += 1
                    }
                }
            }
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
