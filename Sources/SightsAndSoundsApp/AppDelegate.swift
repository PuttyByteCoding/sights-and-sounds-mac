import AppKit
import SightsAndSoundsKit

/// Asks before quitting while background tasks run. ⌘Q used to stop an
/// encode, a remux or a reorganize mid-way without a word; the next
/// launch then marked it failed ("interrupted: the app quit while this
/// job was running"). The Human Interface Guidelines ask an app to
/// confirm before quitting throws work in progress away.
///
/// And lets the writes already on their way land first. A write is a
/// request that takes its time (see `WriteQueue`); quitting on top of
/// one would drop the tag just applied or where the video was stopped.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app's first window; weak, the app owns the model.
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model?.runningJobCount() ?? 0
        guard running > 0 else { return terminateOnceWritesSettle(sender) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = running == 1
            ? "A background task is still running."
            : "\(running) background tasks are still running."
        alert.informativeText = running == 1
            ? "Quitting now stops it part-way. It will show as interrupted in Background Tasks, where it can be run again."
            : "Quitting now stops them part-way. They will show as interrupted in Background Tasks, where they can be run again."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Don't Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        return terminateOnceWritesSettle(sender)
    }

    /// How long a quit waits for writes in flight. Long enough for a
    /// request to a library that is answering; short enough that one
    /// that is not does not hold the app open.
    static let writeGrace: Duration = .seconds(3)

    /// At once when nothing is on its way, as before. Otherwise the quit
    /// goes ahead as soon as the writes have landed, or the grace runs
    /// out.
    private func terminateOnceWritesSettle(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard WriteQueue.inFlightCount > 0 else { return .terminateNow }
        Task {
            await WriteQueue.settleAll(within: Self.writeGrace)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
