import AppKit
import SwiftUI
import SightsAndSoundsKit

/// The file name as real, selectable text, with a double-click that
/// selects the words between the special characters rather than the
/// text system's idea of a word (which stops at a space and steps over
/// an underscore). Click and drag still selects any span; ⌘C copies;
/// right-click offers the name in the tile's two forms.
struct FileNameText: NSViewRepresentable {
    let name: String
    let font: NSFont
    let color: NSColor

    func makeNSView(context: Context) -> WordRunTextView {
        let view = WordRunTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.maximumNumberOfLines = 2
        view.textContainer?.lineBreakMode = .byTruncatingTail
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: WordRunTextView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: WordRunTextView) {
        if view.string != name { view.string = name }
        view.font = font
        view.textColor = color
        view.insertionPointColor = color
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: WordRunTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let container = view.textContainer, let layout = view.layoutManager
        else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    final class WordRunTextView: NSTextView {
        /// A double-click asks for a word: answer with the run between
        /// the special characters around the click.
        override func selectionRange(
            forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity
        ) -> NSRange {
            guard granularity == .selectByWord else {
                return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
            }
            let text = string
            let start = text.wordRun(atUTF16Offset: proposedCharRange.location)
            // A drag with word granularity extends by whole runs at both ends.
            let endOffset = max(proposedCharRange.location, NSMaxRange(proposedCharRange) - 1)
            let end = text.wordRun(atUTF16Offset: endOffset)
            return NSUnionRange(start, end)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            let name = string
            menu.addItem(MenuAction("Copy File Name") { Clipboard.copy(name) })
            menu.addItem(MenuAction("Copy File Name (Letters and Numbers)") {
                Clipboard.copy(name.lettersAndNumbersOnly)
            })
            if selectedRange().length > 0 {
                menu.addItem(.separator())
                menu.addItem(MenuAction("Copy Selection") { [weak self] in
                    guard let self else { return }
                    Clipboard.copy((self.string as NSString).substring(with: self.selectedRange()))
                })
            }
            return menu
        }
    }
}

/// An NSMenuItem that runs a closure — AppKit's target/action, wrapped.
private final class MenuAction: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
