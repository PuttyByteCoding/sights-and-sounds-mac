import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Write-back is a wipe and rewrite, so the preview has to show what is
/// about to be replaced — computed without writing anything.
@Suite struct WritebackPreviewTests {

    /// ffprobe's tag JSON, flattened. Multi-value fields are written
    /// semicolon-joined, so they read back the same way.
    @Test func probeTagsParseIntoFields() {
        let json = """
        {"format": {"tags": {"ARTIST": "Ash & Ember", "GENRE": "Live; Bootleg"}},
         "streams": [{"tags": {"TITLE": "Set One"}}]}
        """
        let parsed = WritebackPreview.parseTags(json: json)
        #expect(parsed["artist"] == ["Ash & Ember"])
        #expect(parsed["genre"] == ["Live", "Bootleg"])
        #expect(parsed["title"] == ["Set One"])
    }

    @Test func emptyValuesAreNotPreviousValues() {
        let parsed = WritebackPreview.parseTags(json: #"{"format": {"tags": {"ARTIST": ""}}}"#)
        #expect(parsed["artist"] == nil)
    }

    /// An amber row is a non-empty value going away — which is the whole
    /// reason the preview exists.
    @Test func replacingSomethingIsDistinctFromAddingIt() {
        let adding = WritebackPreview.Field(
            name: "ARTIST", newValues: ["Ash & Ember"], previousValues: [])
        let replacing = WritebackPreview.Field(
            name: "ARTIST", newValues: ["Ash & Ember"], previousValues: ["Ash and Ember"])
        let unchanged = WritebackPreview.Field(
            name: "ARTIST", newValues: ["Ash & Ember"], previousValues: ["Ash & Ember"])
        #expect(!adding.replacesSomething)
        #expect(replacing.replacesSomething)
        // Writing the same value back is not a loss.
        #expect(!unchanged.replacesSomething)
    }

    /// Offline is skipped whole, everywhere — and the preview says so
    /// rather than letting an unplugged drive look like nothing to do.
    @Test func anOfflineSourceIsPreviewedAsSkipped() throws {
        let f = try FilterFixture()
        let preview = try f.library.previewWriteback(
            itemIDs: [f.show1995.id], fileAccess: OfflineFiles())
        #expect(preview.files.count == 1)
        #expect(preview.files[0].skipReason == "source offline or file missing")
        #expect(preview.writableFiles.isEmpty)
        #expect(preview.skippedFiles.count == 1)
    }

    @Test func headlineFiguresCountOnlyWhatWouldBeWritten() {
        let preview = WritebackPreview(files: [
            .init(
                itemID: UUID(), fileName: "a.mp4", relativePath: "a.mp4",
                fields: [
                    .init(name: "ARTIST", newValues: ["A"], previousValues: ["Old"]),
                    .init(name: "DATE", newValues: ["1995"], previousValues: []),
                ]),
            .init(
                itemID: UUID(), fileName: "b.mp4", relativePath: "b.mp4",
                fields: [], skipReason: "source offline or file missing"),
        ])
        #expect(preview.writableFiles.count == 1)
        #expect(preview.fieldCount == 2)
        #expect(preview.replacedCount == 1)
    }
}

/// Everything unreachable — the offline case, which every file-touching
/// path treats as "skip it whole".
private struct OfflineFiles: FileAccess {
    func isReachable(_ url: URL) -> Bool { false }
    func contentsOfDirectory(at url: URL) throws -> [URL] { [] }
    func allFiles(under url: URL) throws -> [URL] { [] }
    func fileSize(at url: URL) throws -> Int64 { 0 }
    func readFile(at url: URL, chunk: (Data) throws -> Void) throws {}
    func moveFile(at url: URL, to destination: URL) throws {}
    func removeFile(at url: URL) throws {}
}
