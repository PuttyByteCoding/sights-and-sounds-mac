import AppKit
import SwiftUI

/// Keeps a column's content clear of the window's title bar and toolbar.
///
/// SwiftUI gives the sidebar column of a `NavigationSplitView` no top
/// inset unless its content is a `List`, so a hand-built column draws
/// from the window's top edge: the first category row sat clipped behind
/// the traffic lights, and the STATUS heading behind the sidebar toggle.
/// Putting labels under the toolbar icons made the bar taller and the
/// overlap worse.
///
/// Measured rather than written down, because the height moves with the
/// toolbar's display mode, with the interface zoom, and with whether the
/// window has a toolbar at all — a window whose content view already
/// starts below the title bar measures zero and is left alone.
struct TitleBarInset: ViewModifier {
    @State private var inset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.top, inset)
            // Zero-size: the reader is here to find the window, not to
            // take up room. The background, not an overlay, so it never
            // sits over anything clickable.
            .background { Reader(inset: $inset).frame(width: 0, height: 0) }
    }
}

extension View {
    /// Apply to content that fills a window column top to bottom.
    func belowTheTitleBar() -> some View { modifier(TitleBarInset()) }
}

private struct Reader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView { Measuring(inset: $inset) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Measuring: NSView {
        private let inset: Binding<CGFloat>
        private var observer: (any NSObjectProtocol)?

        init(inset: Binding<CGFloat>) {
            self.inset = inset
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not created from a nib") }

        /// Dropped here rather than in `deinit`: a nonisolated deinit
        /// may not touch the token, and this runs for every window the
        /// view leaves, including the last one.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            stopObserving()
        }

        private func stopObserving() {
            guard let observer else { return }
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The toolbar is attached after the view tree is placed, so
            // the first reading would be of a window that has no toolbar
            // yet. Ask again once this pass of the run loop is done.
            measure()
            DispatchQueue.main.async { [weak self] in self?.measure() }
            guard let window else { return }
            stopObserving()
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.measure() }
            }
        }

        private func measure() {
            guard let window, let content = window.contentView else { return }
            let measured = content.bounds.height - window.contentLayoutRect.height
            // A window mid-resize, or one still being built, can report a
            // height that means nothing. No title bar is this tall.
            guard measured.isFinite, measured >= 0, measured < 200 else { return }
            guard abs(measured - inset.wrappedValue) > 0.5 else { return }
            inset.wrappedValue = measured
        }
    }
}
