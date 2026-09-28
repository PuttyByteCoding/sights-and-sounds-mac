import AppKit
import SwiftUI

/// Animation that honours Reduce Motion (System Settings › Accessibility
/// › Display). With it on, the change still happens — at once, without
/// the fade, slide or turn. Nothing in the app read the setting before.
enum Motion {
    static func animation(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// `withAnimation`, unless Reduce Motion is on.
    @MainActor
    static func perform(_ animation: Animation? = .default, _ body: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            body()
        } else {
            withAnimation(animation, body)
        }
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(Motion.animation(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that stands down under Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}
