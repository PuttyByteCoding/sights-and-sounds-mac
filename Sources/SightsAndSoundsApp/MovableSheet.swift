import AppKit
import SwiftUI

/// Closes the panel a view is shown in, when it was presented with
/// `movableSheet`. nil under a real sheet, so a view that can be shown
/// either way falls back to `dismiss`.
struct PanelDismissKey: EnvironmentKey {
    // A constant nil: nothing to share, whatever the closure type says.
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}

/// The presenting scene's `openWindow`, carried into the panel: a panel
/// is hosted outside every SwiftUI scene, where the environment's own
/// `openWindow` has nothing to open with.
struct PanelOpenWindowKey: EnvironmentKey {
    static let defaultValue: OpenWindowAction? = nil
}

extension EnvironmentValues {
    var panelDismiss: (() -> Void)? {
        get { self[PanelDismissKey.self] }
        set { self[PanelDismissKey.self] = newValue }
    }

    var panelOpenWindow: OpenWindowAction? {
        get { self[PanelOpenWindowKey.self] }
        set { self[PanelOpenWindowKey.self] = newValue }
    }
}

extension View {
    /// A sheet that can be dragged: a floating utility panel above the
    /// presenting window, centred on it, keyed like a sheet so Esc and
    /// Return reach its buttons — but movable, so what it covers can be
    /// seen. A macOS sheet is glued to its window; this is not.
    func movableSheet<Content: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(MovableSheetHost(isPresented: isPresented, onDismiss: onDismiss, content: content))
    }

    /// The item form, like `sheet(item:)`: shown while the item is set,
    /// and setting it back to nil closes it.
    func movableSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        movableSheet(
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { shown in if !shown { item.wrappedValue = nil } }),
            onDismiss: onDismiss
        ) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}

/// Zero-size, in the presenting view's background: it knows the parent
/// window, and its coordinator owns the panel for as long as it is up.
private struct MovableSheetHost<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let content: () -> Content
    @Environment(\.openWindow) private var openWindow

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onDismiss = onDismiss
        if isPresented {
            let wrapped = AnyView(
                content()
                    .environment(\.panelDismiss) { isPresented = false }
                    .environment(\.panelOpenWindow, openWindow)
                    .uiZoomed())
            if coordinator.panel == nil {
                coordinator.present(wrapped, over: view.window) { isPresented = false }
            } else {
                coordinator.controller?.rootView = wrapped
            }
        } else if coordinator.panel != nil {
            coordinator.close()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var panel: NSPanel?
        var controller: NSHostingController<AnyView>?
        var onDismiss: (() -> Void)?
        private var onClosed: (() -> Void)?

        func present(_ content: AnyView, over parent: NSWindow?, onClosed: @escaping () -> Void) {
            let controller = NSHostingController(rootView: content)
            controller.sizingOptions = [.preferredContentSize]
            let panel = NSPanel(contentViewController: controller)
            panel.styleMask = [.titled, .closable, .utilityWindow]
            panel.title = ""
            panel.titleVisibility = .hidden
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.delegate = self
            panel.setContentSize(controller.view.fittingSize)
            if let parent {
                let frame = panel.frame
                panel.setFrameOrigin(NSPoint(
                    x: parent.frame.midX - frame.width / 2,
                    y: parent.frame.midY - frame.height / 2))
            } else {
                panel.center()
            }
            self.controller = controller
            self.panel = panel
            self.onClosed = onClosed
            panel.makeKeyAndOrderFront(nil)
        }

        /// SwiftUI says close: the binding went false, or the host went
        /// away. Closing the panel lands in `windowWillClose`, which is
        /// the one place the dismissal is reported from.
        func close() {
            panel?.close()
        }

        func windowWillClose(_ notification: Notification) {
            guard panel != nil else { return }
            panel = nil
            controller = nil
            let closed = onClosed
            onClosed = nil
            closed?()
            onDismiss?()
        }
    }
}
