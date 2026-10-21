import AppKit
import SwiftUI

/// A click, as its own event counts it.
enum ClickKind: Equatable {
    case single, double

    init(clickCount: Int?) {
        self = (clickCount ?? 1) >= 2 ? .double : .single
    }

    /// Read off the event being handled. Only a mouse event carries a
    /// click count — asking a key press for one raises — so a button
    /// pressed from the keyboard or by VoiceOver is a single click.
    init(event: NSEvent?) {
        guard let event, Self.mouseUps.contains(event.type) else {
            self = .single
            return
        }
        self.init(clickCount: event.clickCount)
    }

    private static let mouseUps: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
    ]
}

extension View {
    /// Single and double click in one handler, the way Finder does it:
    /// the first click acts at once, and the second click of a double
    /// opens. `.onTapGesture(count: 2)` stacked with `.onTapGesture`
    /// made SwiftUI hold every single click for the double-click
    /// interval before acting on it, so selecting always lagged.
    func onClicks(single: @escaping () -> Void, double: @escaping () -> Void) -> some View {
        onTapGesture {
            switch ClickKind(clickCount: NSApp.currentEvent?.clickCount) {
            case .single: single()
            case .double: double()
            }
        }
    }
}

/// The same single-or-double handler, as a button rather than a tap
/// gesture: a row that is a button has a button's traits, a focus ring
/// to reach from the keyboard, and VoiceOver reads it as one thing.
/// The action still reads the click's own count, so the first click
/// selects at once and the second opens.
struct ClickButton<Label: View>: View {
    let single: () -> Void
    let double: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button {
            switch ClickKind(event: NSApp.currentEvent) {
            case .single: single()
            case .double: double()
            }
        } label: {
            label
        }
        .buttonStyle(.plain)
    }
}
