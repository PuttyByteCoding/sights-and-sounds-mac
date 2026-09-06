import AppKit

/// The one way text reaches the clipboard from the app — the file-name
/// copies on the grid tile and the player title share it.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
