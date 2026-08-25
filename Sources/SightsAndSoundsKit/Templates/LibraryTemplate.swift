import Foundation

/// The built-in starting points for a new library, per the brief's sample
/// table (§2). Each template demonstrates the vocabulary features its
/// library type leans on; the review screen lets everything be renamed,
/// removed or adjusted before anything is written.
public enum LibraryTemplate: String, CaseIterable, Sendable, Identifiable {
    case concerts
    case learning
    case homeVideos
    case empty

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .concerts: "Concerts"
        case .learning: "Learning"
        case .homeVideos: "Home Videos"
        case .empty: "Empty"
        }
    }

    public var summary: String {
        switch self {
        case .concerts:
            "Live music: bands, recording types with aliases, venues, years with metadata write-back."
        case .learning:
            "Courses and lessons: subject and course categories, lesson ordering, watch state."
        case .homeVideos:
            "Family footage: people, occasions and places."
        case .empty:
            "No categories — build the vocabulary from scratch."
        }
    }

    /// A fresh, fully-editable plan for this template.
    public func plan(named name: String) -> LibraryPlan {
        switch self {
        case .empty:
            return LibraryPlan(name: name)

        case .concerts:
            return LibraryPlan(
                name: name,
                categories: [
                    PlannedCategory(
                        name: "Band",
                        allowMultiple: true,
                        sortOrder: 10,
                        notes: "Bands and solo artists performing in the recording.",
                        isDefaultFocus: true,
                        textFormat: .titleCase,
                        separatorsToSpaces: true,
                        writebackField: "ARTIST"),
                    PlannedCategory(
                        name: "Recording Type",
                        allowMultiple: false,
                        displayAsCheckboxes: true,
                        sortOrder: 20,
                        notes: "Source quality. One per recording.",
                        tags: [
                            PlannedTag(name: "Soundboard", aliases: ["SBD"], isFavorite: true, sortOrder: 10),
                            PlannedTag(name: "Audience", aliases: ["AUD"], sortOrder: 20),
                            PlannedTag(name: "FM Broadcast", aliases: ["FM", "Radio Broadcast"], sortOrder: 30),
                            PlannedTag(name: "Pro-shot", aliases: ["Professional", "Multi-cam"], sortOrder: 40),
                            PlannedTag(name: "Matrix", sortOrder: 50, notes: "Mix of soundboard + audience sources."),
                        ]),
                    PlannedCategory(
                        name: "Venue",
                        allowMultiple: false,
                        sortOrder: 30,
                        sectionLabel: "Show Info",
                        fields: [
                            PlannedTagField(name: "City", sortOrder: 10),
                            PlannedTagField(name: "Origin Country", sortOrder: 20),
                        ]),
                    PlannedCategory(
                        name: "Year",
                        allowMultiple: false,
                        sortOrder: 40,
                        writebackField: "DATE"),
                ],
                itemFields: [
                    PlannedItemField(name: "Show Date", dataType: .date, sortOrder: 10),
                    PlannedItemField(
                        name: "Source URL", dataType: .url, sortOrder: 20,
                        notes: "Original source on archive.org / etree / etc."),
                    PlannedItemField(name: "Setlist Notes", dataType: .longText, sortOrder: 30),
                ])

        case .learning:
            // Subject → Course → Lesson is flat categories, not a schema
            // hierarchy (decided 2026-08-25). Lessons are the media items;
            // their order comes from the Lesson Number field.
            return LibraryPlan(
                name: name,
                categories: [
                    PlannedCategory(
                        name: "Subject",
                        allowMultiple: false,
                        sortOrder: 10,
                        notes: "Broad area — Swift, Photography, Music Theory.",
                        isDefaultFocus: true),
                    PlannedCategory(
                        name: "Course",
                        allowMultiple: false,
                        sortOrder: 20,
                        fields: [
                            PlannedTagField(name: "Course URL", dataType: .url, sortOrder: 10),
                        ]),
                    PlannedCategory(
                        name: "Instructor",
                        allowMultiple: true,
                        sortOrder: 30,
                        textFormat: .titleCase,
                        writebackField: "PERFORMER"),
                    PlannedCategory(
                        name: "Watched",
                        allowMultiple: false,
                        displayAsCheckboxes: true,
                        sortOrder: 40,
                        notes: "Two-value workflow flag.",
                        tags: [
                            PlannedTag(name: "Watched", sortOrder: 10),
                            PlannedTag(name: "Unwatched", sortOrder: 20),
                        ]),
                ],
                itemFields: [
                    PlannedItemField(
                        name: "Lesson Number", dataType: .number, sortOrder: 10,
                        notes: "Orders lessons within a course."),
                ])

        case .homeVideos:
            return LibraryPlan(
                name: name,
                categories: [
                    PlannedCategory(
                        name: "People",
                        allowMultiple: true,
                        displayAsCheckboxes: true,
                        sortOrder: 10,
                        notes: "Who's in the video. Stable small set — checkboxes."),
                    PlannedCategory(
                        name: "Occasion",
                        allowMultiple: false,
                        sortOrder: 20,
                        notes: "Birthdays, holidays, trips.",
                        isDefaultFocus: true),
                    PlannedCategory(
                        name: "Location",
                        allowMultiple: false,
                        sortOrder: 30,
                        writebackField: "LOCATION"),
                ])
        }
    }
}
