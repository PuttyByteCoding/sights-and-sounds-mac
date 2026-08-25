import AVKit
import SwiftUI
import SightsAndSoundsKit

/// Basic native playback: AVKit's transport, auto-seek into a clip's range.
/// The player owns playback and nothing else — tagging, OCR and clip
/// authoring are separate features reached *from* a playing item (the
/// 4,382-line lesson). Scrub previews, waveforms and the keyboard map land
/// in the next slice.
struct PlayerView: View {
    @Environment(AppModel.self) private var app
    let request: PlayerRequest

    @State private var player: AVPlayer?
    @State private var title = "Player"
    @State private var loadError: String?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else if let loadError {
                ContentUnavailableView(
                    "Cannot Play", systemImage: "play.slash",
                    description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .frame(minWidth: 640, minHeight: 400)
        .task { load() }
    }

    private func load() {
        do {
            let library = try app.library(for: request.libraryID)
            guard let item = try library.writer.read({
                try MediaItem.fetchOne($0, key: request.itemID)
            }) else {
                loadError = "The item no longer exists."
                return
            }
            guard let source = try library.sources().first(where: { $0.id == item.sourceID }),
                  source.isOnline(using: LiveFileAccess())
            else {
                loadError = "The item's source is offline."
                return
            }
            title = item.fileName
            let url = URL(fileURLWithPath: source.rootPath, isDirectory: true)
                .appendingPathComponent(item.relativePath)
            let avPlayer = AVPlayer(url: url)
            // Embedded clip: start at the in-point.
            if let start = item.clipStartSeconds {
                avPlayer.seek(to: CMTime(seconds: start, preferredTimescale: 600))
            }
            player = avPlayer
            avPlayer.play()
        } catch {
            loadError = "\(error)"
        }
    }
}
