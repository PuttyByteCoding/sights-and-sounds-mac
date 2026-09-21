/// Every library migration, listed in the order it was shipped. The
/// tests that check "a library ends up fully migrated" share this one
/// set, so a new migration is one line here and not the same line in
/// five files.
///
/// It is written out rather than read from the migrator on purpose: the
/// names are history, and a test that asked the migrator what it contains
/// could never notice one being renamed or dropped. (`appliedMigrations`
/// is a set, so these tests have never checked the order.)
enum ExpectedMigrations {
    static let all: Set<String> = [
        "phase0", "phase1", "phase2", "phase4", "phase5", "phase6", "phase7", "phase7b",
        "phase7c", "phase7d", "phase8", "phase8b", "extensionOverrides", "categoryColors",
        "segmentRoles", "categoryDisplayStyle", "importBoxes", "jobPriority",
        "playbackIssueEvidence", "moveSessions", "separatorCharacters", "tagAnalysis",
        "savedFilters", "tagAnalysisMarker", "jsonSchemas", "fingerprintUnsignedRetry",
        "tagAnalysisIgnore", "searchRecipe", "segmentsFollowTheirFile",
        "segmentLookupIndex", "moveJournal",
    ]
}
