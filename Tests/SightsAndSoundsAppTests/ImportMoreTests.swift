import Testing

@testable import SightsAndSoundsApp

/// "Import more" on the finished sheet. It sent the window back to the
/// Source step, and choosing the source there rescanned the whole folder,
/// though Review already held the scan with what just went in marked as
/// known.
@Suite struct ImportMoreTests {
    @Test func importMoreStaysOnReviewWithTheScanItHas() {
        #expect(ImportView.Step.review.afterImportMore == .review)
    }

    /// A cancelled or failed run rescans by itself, since what landed is
    /// not known here. "Import more" lets that scan finish.
    @Test func importMoreLeavesARescanAfterAFailedRunRunning() {
        #expect(ImportView.Step.scan.afterImportMore == .scan)
    }
}
