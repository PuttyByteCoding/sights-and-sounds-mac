import SightsAndSoundsKit
import SwiftUI

extension View {
    /// While `active` — the view is waiting on work it queued — keeps
    /// `paused` saying whether that library's queue is paused, so the view
    /// can say why nothing moves. A wait lasts until Resume when tasks are
    /// paused, and a busy button with no reason given looks stuck. Read
    /// every 2 s and only while waiting (a pause is not in the database,
    /// so there is nothing to observe); per runner, since a lane can be
    /// paused on its own.
    func watchingQueuePause(_ paused: Binding<Bool>, while active: Bool, libraryID: UUID?) -> some View {
        modifier(QueuePauseWatch(paused: paused, active: active, libraryID: libraryID))
    }
}

private struct QueuePauseWatch: ViewModifier {
    @Environment(AppModel.self) private var app
    @Binding var paused: Bool
    let active: Bool
    let libraryID: UUID?

    /// Both: a library picked while waiting (the sweep panel's picker)
    /// must be watched from then on, not the one the wait began on.
    private struct Key: Hashable {
        let active: Bool
        let libraryID: UUID?
    }

    func body(content: Content) -> some View {
        content.task(id: Key(active: active, libraryID: libraryID)) {
            guard active, let libraryID, let runner = try? app.runner(for: libraryID) else {
                paused = false
                return
            }
            while !Task.isCancelled {
                let isPaused = await runner.isPaused
                // A read the key change cancelled must not land after the
                // new watch's own first read.
                guard !Task.isCancelled else { return }
                paused = isPaused
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
