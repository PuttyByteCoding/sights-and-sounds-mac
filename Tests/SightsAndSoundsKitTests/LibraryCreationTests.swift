import Foundation
import GRDB
import Testing
@testable import SightsAndSoundsKit

/// Phase 2: templates, the review-plan model, and plan execution.
@Suite struct LibraryCreationTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Templates

    @Test func templatesMatchTheBriefsSampleTable() {
        let concerts = LibraryTemplate.concerts.plan(named: "C")
        #expect(concerts.categories.map(\.name) == ["Band", "Recording Type", "Venue", "Year"])
        let band = concerts.categories[0]
        #expect(band.allowMultiple && band.writebackField == "ARTIST")
        let recType = concerts.categories[1]
        #expect(!recType.allowMultiple && recType.displayStyle == .checkboxes)
        #expect(recType.tags.contains { $0.name == "Soundboard" && $0.aliases == ["SBD"] })
        #expect(concerts.categories[2].sectionLabel == "Show Info")
        #expect(concerts.categories[3].writebackField == "DATE")

        let learning = LibraryTemplate.learning.plan(named: "L")
        #expect(learning.categories.map(\.name) == ["Subject", "Course", "Instructor", "Watched"])
        #expect(learning.itemFields.contains { $0.name == "Lesson Number" && $0.dataType == .number })
        // The two-value workflow flag.
        #expect(learning.categories[3].tags.count == 2)

        let home = LibraryTemplate.homeVideos.plan(named: "H")
        #expect(home.categories.map(\.name) == ["People", "Occasion", "Location"])
        #expect(home.categories[0].allowMultiple && home.categories[0].displayStyle == .checkboxes)

        #expect(LibraryTemplate.empty.plan(named: "E").categories.isEmpty)
    }

    @Test func everyTemplateProducesAValidPlan() {
        for template in LibraryTemplate.allCases {
            #expect(template.plan(named: "Test").validationErrors().isEmpty)
        }
    }

    // MARK: Plan validation

    @Test func planValidationCatchesReviewMistakes() {
        var plan = LibraryTemplate.concerts.plan(named: "C")

        plan.categories[0].name = "Year"  // duplicate of an existing category
        #expect(plan.validationErrors().contains { $0.contains("Duplicate category") })

        plan = LibraryTemplate.concerts.plan(named: "C")
        plan.categories[0].name = "  "
        #expect(plan.validationErrors().contains { $0.contains("empty name") })

        plan = LibraryTemplate.concerts.plan(named: "")
        #expect(plan.validationErrors().contains { $0.contains("needs a name") })
    }

    @Test func excludingResolvesDuplicates() {
        var plan = LibraryTemplate.concerts.plan(named: "C")
        plan.categories[0].name = "Year"
        plan.categories[3].include = false  // exclude the original Year
        #expect(plan.validationErrors().isEmpty)
    }

    // MARK: Creation

    @Test func createWritesTheReviewedPlanExactly() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try AppDatabase.openInMemory()

        var plan = LibraryTemplate.concerts.plan(named: "My Concerts")
        plan.categories[0].name = "Artist"       // renamed in review
        plan.categories[3].include = false       // Year excluded in review
        plan.itemFields[2].include = false       // Setlist Notes excluded
        let source = Source(name: "Shows", rootPath: "/Volumes/Media/Shows")

        let library = try LibraryCreator.create(
            at: dir.appendingPathComponent("My Concerts.sqlite"),
            plan: plan, firstSource: source, registerIn: app)

        #expect(try library.info()?.name == "My Concerts")

        let categories = try library.writer.read {
            try TagCategory.order(sql: "sortOrder").fetchAll($0)
        }
        #expect(categories.map(\.name) == ["Artist", "Recording Type", "Venue"])
        #expect(categories[0].writebackField == "ARTIST")

        // Tags and aliases landed under the right category.
        let recType = categories[1]
        let tags = try library.writer.read {
            try Tag.filter(sql: "tagCategoryID = ?", arguments: [recType.id])
                .order(sql: "sortOrder").fetchAll($0)
        }
        #expect(tags.first?.name == "Soundboard")
        let aliases = try library.writer.read {
            try TagAlias.filter(sql: "tagID = ?", arguments: [tags[0].id]).fetchAll($0)
        }
        #expect(aliases.map(\.alias) == ["SBD"])

        // Tag-scope fields attach to their category; excluded item field absent.
        let fields = try library.writer.read { try FieldDefinition.fetchAll($0) }
        #expect(fields.contains { $0.name == "City" && $0.scope == .tag && $0.tagCategoryID == categories[2].id })
        #expect(fields.contains { $0.name == "Show Date" && $0.scope == .mediaItem })
        #expect(!fields.contains { $0.name == "Setlist Notes" })

        // First source in place; library registered.
        #expect(try library.writer.read { try Source.fetchAll($0) }.map(\.name) == ["Shows"])
        #expect(try app.libraries().map(\.name) == ["My Concerts"])
    }

    @Test func excludedCategoryLeavesNothingBehind() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var plan = LibraryTemplate.learning.plan(named: "L")
        plan.categories[3].include = false  // Watched, which carries tags

        let library = try LibraryCreator.create(
            at: dir.appendingPathComponent("L.sqlite"), plan: plan)
        let names = try library.writer.read { try TagCategory.fetchAll($0) }.map(\.name)
        #expect(!names.contains("Watched"))
        // Its tags don't exist under any category.
        let tagCount = try library.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tag")!
        }
        #expect(tagCount == 0)
    }

    @Test func invalidPlanWritesNothingAtAll() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Broken.sqlite")

        var plan = LibraryTemplate.concerts.plan(named: "C")
        plan.categories[0].name = "Year"  // duplicate → invalid

        #expect(throws: LibraryPlanError.self) {
            try LibraryCreator.create(at: url, plan: plan)
        }
        // Validation precedes any file I/O.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Analysis-rule storage (phase2 migration)

    @Test func analysisRulesPersistWithOrderIntact() throws {
        let library = try LibraryDatabase.openInMemory()
        #expect(try library.appliedMigrations() == ["phase0", "phase1", "phase2", "phase4", "phase5", "phase6", "phase7", "phase7b", "phase7c", "phase7d", "phase8", "phase8b", "extensionOverrides", "categoryColors", "segmentRoles", "categoryDisplayStyle", "importBoxes", "jobPriority", "playbackIssueEvidence", "moveSessions", "separatorCharacters"])

        let rules = [
            AnalysisRule(
                sortOrder: 20,
                matchJSON: #"{"type":"numericRange","min":1960,"max":2030}"#,
                actionsJSON: #"[{"type":"assignCategory","category":"Year"}]"#),
            AnalysisRule(
                sortOrder: 10,
                matchJSON: #"{"type":"keyEquals","key":"band"}"#,
                actionsJSON: #"[{"type":"stripPrefix","prefix":"the "},{"type":"assignCategory","category":"Band"}]"#),
        ]
        try library.writer.write { db in
            for rule in rules { try rule.insert(db) }
        }
        let ordered = try library.writer.read {
            try AnalysisRule.order(sql: "sortOrder").fetchAll($0)
        }
        #expect(ordered.map(\.sortOrder) == [10, 20])
        // Action order inside the JSON survives verbatim.
        #expect(ordered[0].actionsJSON.contains(#"stripPrefix"#))
    }
}
