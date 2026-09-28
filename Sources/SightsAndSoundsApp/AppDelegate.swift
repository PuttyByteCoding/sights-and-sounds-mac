import AppKit
import SightsAndSoundsKit

/// Asks before quitting while background tasks run. ⌘Q used to stop an
/// encode, a remux or a reorganize mid-way without a word; the next
/// launch then marked it failed ("interrupted: the app quit while this
/// job was running"). The Human Interface Guidelines ask an app to
/// confirm before quitting throws work in progress away.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app's first window; weak, the app owns the model.
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model?.runningJobCount() ?? 0
        guard running > 0 else { return .terminateNow }
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
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
