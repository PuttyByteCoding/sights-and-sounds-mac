import Foundation
import Testing
@testable import SightsAndSoundsKit

/// The Phase 1 requirement Learning forces: ordering a listing by a field
/// value, numerically for number fields. The old app's browse sorts could
/// not express this at all.
@Suite struct FieldSortingTests {

    /// A Learning-shaped library: one course, lessons 1, 2, 3 and 10
    /// inserted out of order, lesson numbers as a media-item number field.
    private struct LearningFixture {
        let library: LibraryDatabase
        let source = Source(name: "Courses", rootPath: "/Volumes/Media/Courses")
        let lessonNumber = FieldDefinition(name: "Lesson Number", dataType: .number, scope: .mediaItem)
        let lessons: [MediaItem]  // insertion order: 10, 2, 1, 3
        let unnumbered: MediaItem

        init() throws {
            library = try LibraryDatabase.openInMemory()
            let sid = source.id
            let values = ["10", "2", "1", "3"]
            lessons = values.enumerated().map { i, n in
                MediaItem(
                    sourceID: sid, kind: .video,
                    relativePath: "swift/lesson-\(n).mp4", needsReview: false)
            }
            unnumbered = MediaItem(
                sourceID: sid, kind: .video, relativePath: "swift/intro.mp4", needsReview: false)
            try library.writer.write { db in
                try source.insert(db)
                try lessonNumber.insert(db)
                for (i, lesson) in lessons.enumerated() {
                    try lesson.insert(db)
                    try MediaItemFieldValue(
                        mediaItemID: lesson.id, definition: lessonNumber, value: values[i]
                    ).insert(db)
                }
                try unnumbered.insert(db)
            }
        }
    }

    @Test func numberFieldsSortNumericallyNotLexically() throws {
        let f = try LearningFixture()
        let ordered = try f.library.mediaItems(
            matching: MediaFilter(), kind: .video,
            orderedBy: .fieldValue(f.lessonNumber.id))
        // Numeric: 1, 2, 3, 10 — lexical would put "10" before "2".
        #expect(ordered.map(\.fileName) == [
            "lesson-1.mp4", "lesson-2.mp4", "lesson-3.mp4", "lesson-10.mp4", "intro.mp4",
        ])
    }

    @Test func itemsWithoutAValueSortLastEvenDescending() throws {
        let f = try LearningFixture()
        let ordered = try f.library.mediaItems(
            matching: MediaFilter(), kind: .video,
            orderedBy: .fieldValue(f.lessonNumber.id, ascending: false))
        #expect(ordered.map(\.fileName) == [
            "lesson-10.mp4", "lesson-3.mp4", "lesson-2.mp4", "lesson-1.mp4", "intro.mp4",
        ])
    }

    @Test func orderingComposesWithFiltering() throws {
        let f = try LearningFixture()
        let ordered = try f.library.mediaItems(
            matching: MediaFilter(required: [.subtree("swift")]), kind: .video,
            orderedBy: .fieldValue(f.lessonNumber.id))
        #expect(ordered.count == 5)
        #expect(ordered.first?.fileName == "lesson-1.mp4")
    }

    @Test func textFieldsSortAsText() throws {
        let library = try LibraryDatabase.openInMemory()
        let source = Source(name: "S", rootPath: "/tmp/media")
        let venue = FieldDefinition(name: "Venue", dataType: .text, scope: .mediaItem)
        let names = ["zebra Hall", "Apollo", "midtown Arena"]
        try library.writer.write { db in
            try source.insert(db)
            try venue.insert(db)
            for (i, n) in names.enumerated() {
                let item = MediaItem(
                    sourceID: source.id, kind: .video,
                    relativePath: "v/\(i).mp4", needsReview: false)
                try item.insert(db)
                try MediaItemFieldValue(mediaItemID: item.id, definition: venue, value: n).insert(db)
            }
        }
        let ordered = try library.mediaItems(
            matching: MediaFilter(), kind: .video, orderedBy: .fieldValue(venue.id))
        // NOCASE text ordering; numericValue is nil for text fields.
        #expect(ordered.map(\.fileName) == ["1.mp4", "2.mp4", "0.mp4"])
    }

    @Test func numericValueMaintenanceFollowsDataType() {
        let number = FieldDefinition(name: "N", dataType: .number, scope: .mediaItem)
        let text = FieldDefinition(name: "T", dataType: .text, scope: .mediaItem)
        let id = UUID()

        var v = MediaItemFieldValue(mediaItemID: id, definition: number, value: " 12.5 ")
        #expect(v.numericValue == 12.5)
        v.setValue("not a number", definition: number)
        #expect(v.numericValue == nil)

        let t = MediaItemFieldValue(mediaItemID: id, definition: text, value: "42")
        #expect(t.numericValue == nil)
    }
}
