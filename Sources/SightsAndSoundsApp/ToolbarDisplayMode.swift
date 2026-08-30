import AppKit
import SwiftUI

/// Makes icons-with-labels the toolbar's default, once, and then gets out
/// of the way.
///
/// SwiftUI exposes no toolbar display-mode API, and AppKit's default here
/// comes up icon-only — every button a glyph you have to hover to
/// identify. macOS *does* remember a per-toolbar choice, but only for a
/// toolbar that autosaves its configuration, which SwiftUI does not turn
/// on; without it the choice is discarded at quit, which is why it had to
/// be set again every launch.
///
/// So this does two things and each matters: it enables autosaving, and
/// it applies the icon-and-label default **only when no saved
/// configuration exists**. First launch gets labels; any later change is
/// the user's and survives, rather than being stamped back over on the
/// next window.
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
                let key = "NSToolbar Configuration \(toolbar.identifier)"
                let hasSavedChoice = UserDefaults.standard.object(forKey: key) != nil
                toolbar.autosavesConfiguration = true
                if !hasSavedChoice {
                    toolbar.displayMode = .iconAndLabel
                }
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
