import Foundation
import Testing

@testable import SightsAndSoundsKit

/// A value this build does not know — written by a newer build, or a
/// hand-edit typo — costs that one setting, not the whole file. It used
/// to fail the decode, and `load` then replaced every setting with its
/// default (the next save writing those over the file).
@Suite struct SettingsToleranceTests {
    private func json(_ settings: AppSettings) throws -> String {
        String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    }

    @Test func anUnknownEnumValueFallsBackForThatKeyOnly() throws {
        var settings = AppSettings()
        settings.loopVideos = !AppSettings().loopVideos
        var text = try json(settings)
        let keyMap = "\"keyMap\":\"\(AppSettings().keyMap.rawValue)\""
        try #require(text.contains(keyMap))
        text = text.replacingOccurrences(of: keyMap, with: "\"keyMap\":\"fromTheFuture\"")

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(text.utf8))

        #expect(decoded.loopVideos == settings.loopVideos)
        #expect(decoded.keyMap == AppSettings().keyMap)
    }

    @Test func anUnknownTileValueDropsThatEntryOnly() throws {
        var settings = AppSettings()
        settings.startVideosMuted = !AppSettings().startVideosMuted
        let before = settings.grid.views.map { $0.placements.flatMap(\.entries).count }.reduce(0, +)
        var text = try json(settings)
        try #require(text.contains("\"duration\""))
        text = text.replacingOccurrences(of: "\"duration\"", with: "\"hologram\"")

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(text.utf8))

        #expect(decoded.startVideosMuted == settings.startVideosMuted)
        let after = decoded.grid.views.map { $0.placements.flatMap(\.entries).count }.reduce(0, +)
        #expect(after > 0)
        #expect(after < before)
        #expect(decoded.grid.views.count == settings.grid.views.count)
    }
}
