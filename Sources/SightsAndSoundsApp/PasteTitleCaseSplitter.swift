import AppKit
import SightsAndSoundsKit

/// ⌘V into ANY text field in the app: a pasted run that looks like
/// title case without its spaces — "BenFolds" off a file name — gets
/// them back, "Ben Folds". One local key monitor for the whole app,
/// rather than a modifier on each of a hundred fields: it sees the ⌘V
/// before the field does, swaps the pasteboard's string for the split
/// one while the paste runs, and puts the original back on the next
/// turn of the run loop, so what you copied is still what you copied
/// for the next app. Anything that does not look like title case
/// passes through untouched, and the setting turns the whole thing
/// off. Paste from the Edit menu bypasses the key monitor and pastes
/// as copied.
@MainActor
final class PasteTitleCaseSplitter {
    static let shared = PasteTitleCaseSplitter()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Self.shared.intercept(event) }
            return event
        }
    }

    private func intercept(_ event: NSEvent) {
        guard AppSettingsStore.shared.current.pasteSplitsTitleCase,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "v",
              event.window?.firstResponder is NSTextView
        else { return }
        let pasteboard = NSPasteboard.general
        guard let original = pasteboard.string(forType: .string) else { return }
        let split = original.splittingTitleCaseWords
        guard split != original else { return }
        pasteboard.clearContents()
        pasteboard.setString(split, forType: .string)
        // The paste runs inside this event's dispatch; the original is
        // back before anything else can read it.
        DispatchQueue.main.async {
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
        }
    }
}
