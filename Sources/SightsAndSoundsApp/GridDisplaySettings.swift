import SwiftUI
import SightsAndSoundsKit

/// The grid/queue display configuration as LIVE observable state — the
/// View Options slider drives every cell through normal observation,
/// with no refetch in the size path (#91). Loaded once at launch;
/// persisted to AppSettingsStore when a change settles, so
/// settings.json isn't rewritten at drag rate.
@Observable @MainActor
final class GridDisplaySettings {
    static let shared = GridDisplaySettings()

    var grid: GridSettings = AppSettingsStore.shared.current.grid

    func persist() {
        let grid = grid
        AppSettingsStore.shared.update { $0.grid = grid }
    }
}
