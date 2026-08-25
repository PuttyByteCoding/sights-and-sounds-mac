import SwiftUI
import SightsAndSoundsKit

/// Early app shell. Proves the package runs as a windowed macOS app and
/// can open a library; the real browse workspace arrives in Phase 3.
@main
struct SightsAndSoundsApp: App {
    var body: some Scene {
        WindowGroup {
            Phase0View()
        }
    }
}

struct Phase0View: View {
    @State private var statusText = "No library open."

    var body: some View {
        VStack(spacing: 12) {
            Text("Sights and Sounds")
                .font(.largeTitle)
            Text("Phase 1 — libraries, sources, schema, jobs")
                .foregroundStyle(.secondary)
            Button("Create scratch library") { createScratchLibrary() }
            Text(statusText)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 280)
    }

    private func createScratchLibrary() {
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("SightsAndSoundsScratch", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Scratch.sqlite")
            let library = try LibraryDatabase.open(at: url)
            let info = try library.ensureInfo(name: "Scratch")
            let applied = try library.appliedMigrations().sorted()
            statusText = "Opened \(info.name) at \(url.path)\nMigrations applied: \(applied.joined(separator: ", "))"
        } catch {
            statusText = "Failed: \(error)"
        }
    }
}
