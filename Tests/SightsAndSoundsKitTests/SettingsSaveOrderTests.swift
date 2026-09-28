import Foundation
import Testing

@testable import SightsAndSoundsKit

/// What is on disk is the newest settings. The save used to run after
/// the lock was released, so two quick updates could write in the wrong
/// order: memory said B, the file kept A, and B was gone next launch.
@Suite struct SettingsSaveOrderTests {
    @Test func theFileEndsOnTheNewestSettingsUnderConcurrentUpdates() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-order-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppSettingsStore(fileURL: url)

        for _ in 0..<5 {
            DispatchQueue.concurrentPerform(iterations: 64) { index in
                store.update { $0.tagPanelRowOrder.append("row-\(index)") }
            }
            let onDisk = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
            #expect(onDisk.tagPanelRowOrder == store.current.tagPanelRowOrder)
        }
    }
}
