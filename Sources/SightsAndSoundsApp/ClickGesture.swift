import AppKit
import SwiftUI

/// A click, as its own event counts it.
enum ClickKind: Equatable {
    case single, double

    init(clickCount: Int?) {
        self = (clickCount ?? 1) >= 2 ? .double : .single
    }
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
