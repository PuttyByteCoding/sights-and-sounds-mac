import Foundation
import Testing

@testable import SightsAndSoundsKit

/// A queued job outlives the session that queued it: at the next launch
/// the runner must know its kind, or the row fails with "no registered
/// job type". RepairJob was registered only by the Review window, just
/// before it enqueued one, so a repair still queued at quit failed on the
/// next launch. Every job type now lives in one catalog the app hands its
/// runners.
@Suite struct JobCatalogTests {
    @Test func theCatalogHoldsEveryJobTypeTheKitDeclares() throws {
        let kitSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SightsAndSoundsKit", isDirectory: true)
        let pattern = try Regex(#"static let kind = "([^"]+)""#)
        var declared = Set<String>()
        let files = try #require(FileManager.default.enumerator(at: kitSources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: pattern) {
                if let kind = match.output[1].substring { declared.insert(String(kind)) }
            }
        }
        #expect(declared.count >= 19)

        let catalogued = JobCatalog.all.map { $0.kind }
        #expect(Set(catalogued) == declared)
        #expect(catalogued.count == Set(catalogued).count, "a kind is listed twice")
    }

    @Test func aRunnerBuiltFromTheCatalogHandlesARepair() async throws {
        let library = try LibraryDatabase.openInMemory()
        let runner = JobRunner(library: library, jobTypes: JobCatalog.all)
        #expect(await runner.handles(kind: RepairJob.kind))
    }
}
