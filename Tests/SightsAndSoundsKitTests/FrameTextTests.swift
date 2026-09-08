import Foundation
import Testing
@testable import SightsAndSoundsKit

/// One frame, read on demand: the lines Vision finds at a moment, or a
/// thrown error when the frame itself cannot be produced — never a
/// silent empty list for a broken read.
@Suite struct FrameTextTests {
    @Test func burnedInTextComesBackAsLines() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-frame-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("v.mp4")
        try await DemoMediaFactory.writeVideo(to: url, seconds: 3, variant: 2, overlayText: "RIVERBEND 1995")

        let lines = try await OcrJob.readLines(fileURL: url, atSeconds: 1.0)
        #expect(lines.contains { $0.localizedCaseInsensitiveContains("RIVERBEND") })
    }

    @Test func aFrameThatCannotBeProducedThrows() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-frame-missing-\(UUID().uuidString).mp4")
        await #expect(throws: (any Error).self) {
            _ = try await OcrJob.readLines(fileURL: missing, atSeconds: 0)
        }
    }
}
