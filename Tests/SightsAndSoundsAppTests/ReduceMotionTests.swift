import SwiftUI
import Testing

@testable import SightsAndSoundsApp

/// With Reduce Motion on (System Settings › Accessibility › Display),
/// the app's fades, slides and chevron turns go away: the change still
/// happens, at once. Nothing read the setting before.
@Suite struct ReduceMotionTests {
    @Test func reduceMotionDropsTheAnimation() {
        #expect(Motion.animation(.easeOut(duration: 0.15), reduceMotion: true) == nil)
    }

    @Test func otherwiseTheAnimationStands() {
        #expect(Motion.animation(.easeOut(duration: 0.15), reduceMotion: false) == .easeOut(duration: 0.15))
    }
}
