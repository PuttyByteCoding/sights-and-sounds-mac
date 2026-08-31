import AppKit
import SwiftUI

/// The candidate's raw text, selectable — click and drag a span, then
/// right-click → "New Tag from …" with exactly the selected characters.
///
/// AppKit-backed because this is the one thing SwiftUI text cannot do:
/// expose the SELECTION to a context menu. The view is read-only; the
/// editable field above it stays the place where the whole value gets
/// trimmed by hand.
struct SelectableValueText: NSViewRepresentable {
    let text: String
    let onNewTag: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SelectionMenuTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? SelectionMenuTextView else { return }
        textView.onNewTag = onNewTag
        if textView.string != text {
            textView.string = text
            textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textColor = NSColor(Theme.Text.secondary)
        }
    }

    final class SelectionMenuTextView: NSTextView {
        var onNewTag: ((String) -> Void)?

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = super.menu(for: event) ?? NSMenu()
            let selection = (string as NSString).substring(with: selectedRange())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selection.isEmpty else { return menu }

            let title = selection.count > 40
                ? "New Tag from “\(selection.prefix(40))…”"
                : "New Tag from “\(selection)”"
            let item = NSMenuItem(title: title, action: #selector(makeTag(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = selection
            menu.insertItem(item, at: 0)
            menu.insertItem(NSMenuItem.separator(), at: 1)
            return menu
        }

        @objc private func makeTag(_ sender: NSMenuItem) {
            guard let selection = sender.representedObject as? String else { return }
            onNewTag?(selection)
        }
    }
}
