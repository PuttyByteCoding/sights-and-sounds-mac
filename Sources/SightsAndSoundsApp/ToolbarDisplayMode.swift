import AppKit
import SwiftUI

/// Puts a label under every toolbar icon, on every window, every launch.
///
/// SwiftUI exposes no toolbar display-mode API, and AppKit's default here
/// comes up icon-only — every button a glyph you have to hover to
/// identify.
///
/// This used to set icon-and-label only when no saved configuration
/// existed, so that a later choice of the user's would survive. That
/// deference was the bug: a toolbar saved as icon-only once stays
/// icon-only for good, and the library window was found in exactly that
/// state — nine bare glyphs across the top. An icon without a word under
/// it is not a thing this app ships, so the display mode is no longer
/// negotiable.
///
/// Autosaving stays on, and it still carries what it should: which items
/// are in the toolbar and in what order. Only the labels are forced.
///
/// It is a zero-size background view because the toolbar belongs to the
/// NSWindow, and a SwiftUI view's only route to its window is an NSView
/// that has actually been placed in one.
struct ToolbarDisplayMode: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Applier() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Applier: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The toolbar is attached after the view tree is placed, so
            // ask again once this pass of the run loop has finished.
            DispatchQueue.main.async { [weak self] in
                guard let toolbar = self?.window?.toolbar else { return }
                toolbar.autosavesConfiguration = true
                toolbar.displayMode = .iconAndLabel
            }
        }
    }
}

extension View {
    /// Apply to any window that owns a toolbar.
    func defaultToolbarShowsLabels() -> some View {
        background(ToolbarDisplayMode().frame(width: 0, height: 0))
    }
}
