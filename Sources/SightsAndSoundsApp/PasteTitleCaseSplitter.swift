import AppKit
import SightsAndSoundsKit

/// ⌘V into ANY text field in the app: a pasted run that looks like
/// title case without its spaces — "BenFolds" off a file name — gets
/// them back, "Ben Folds". One local key monitor for the whole app,
/// rather than a modifier on each of a hundred fields: it sees the ⌘V
/// before the field does and, when the pasteboard's string would
/// change, performs the paste ITSELF — the split text goes into the
/// field editor as typed text, replacing the selection — and swallows
/// the key. Nothing on the pasteboard is touched, so what you copied
/// is still what you copied for the next app, and nothing depends on
/// when the field would have got round to reading it. Anything that
/// does not look like title case is left to the ordinary paste, and
/// the setting turns the whole thing off.
///
/// Paste from the Edit menu bypasses the key monitor and pastes as
/// copied; a control that reads the pasteboard itself asks `split(_:)`.
@MainActor
final class PasteTitleCaseSplitter {
    static let shared = PasteTitleCaseSplitter()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.intercept(event) == true ? nil : event
        }
    }

    /// The pasteboard's text as a paste should read it: split when the
    /// setting is on and it looks like title case, else as it is.
    static func split(_ text: String) -> String {
        AppSettingsStore.shared.current.pasteSplitsTitleCase ? text.splittingTitleCaseWords : text
    }

    /// True when the paste was performed here and the key is spent.
    private func intercept(_ event: NSEvent) -> Bool {
        guard AppSettingsStore.shared.current.pasteSplitsTitleCase,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "v",
              let textView = event.window?.firstResponder as? NSTextView,
              textView.isEditable,
              let original = NSPasteboard.general.string(forType: .string)
        else { return false }
        let split = original.splittingTitleCaseWords
        guard split != original else { return false }
        textView.insertText(split, replacementRange: textView.selectedRange())
        return true
    }
}
