import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The optional log file gets every line, in order — now written on a
/// queue of its own rather than on whichever thread logged (often the
/// main one), with a file handle opened per line.
@Suite(.serialized) struct LogFileTests {
    @Test func linesReachTheFileInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-log-file-\(UUID().uuidString)", isDirectory: true)
        defer {
            AppSettingsStore.shared.update { $0.logDirectory = nil }
            try? FileManager.default.removeItem(at: directory)
        }
        AppSettingsStore.shared.update { $0.logDirectory = directory.path }
        let marker = UUID().uuidString.prefix(8)

        for n in 0..<200 { AppLog.shared.info("test", "\(marker) line \(n)") }
        AppLog.shared.flushFileForTesting()

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        let ours = text.split(separator: "\n").filter { $0.contains(marker) }
        #expect(ours.count == 200)
        #expect(ours.first?.hasSuffix("line 0") == true)
        #expect(ours.last?.hasSuffix("line 199") == true)
    }
}
