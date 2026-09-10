import Foundation
import Testing
@testable import SightsAndSoundsKit

/// Two clean modifier taps inside the window, and nothing else.
@Suite struct DoubleTapDetectorTests {
    private func run(_ steps: [(DoubleTapDetector.Event, TimeInterval)]) -> [Bool] {
        var detector = DoubleTapDetector(window: 0.35)
        return steps.map { detector.feed($0.0, at: $0.1) }
    }

    @Test func twoQuickTapsFireOnTheSecondUp() {
        let fired = run([(.modifierDown, 0), (.modifierUp, 0.05), (.modifierDown, 0.15), (.modifierUp, 0.2)])
        #expect(fired == [false, false, false, true])
    }

    @Test func twoSlowTapsAreTwoFirstTaps() {
        let fired = run([(.modifierDown, 0), (.modifierUp, 0.05), (.modifierDown, 0.6), (.modifierUp, 0.65)])
        #expect(!fired.contains(true))
    }

    /// Shift held for a shifted arrow is a chord: the key between the
    /// down and the up disqualifies it, and the tap after starts fresh.
    @Test func aKeyBetweenDownAndUpIsAChordNotATap() {
        let fired = run([
            (.modifierDown, 0), (.otherKey, 0.02), (.modifierUp, 0.05),
            (.modifierDown, 0.1), (.modifierUp, 0.15),
        ])
        #expect(!fired.contains(true))
    }

    @Test func aKeyBetweenTheTapsBreaksTheGesture() {
        let fired = run([
            (.modifierDown, 0), (.modifierUp, 0.05), (.otherKey, 0.08),
            (.modifierDown, 0.1), (.modifierUp, 0.15),
        ])
        #expect(!fired.contains(true))
    }

    @Test func aLongHoldIsNotATap() {
        let fired = run([(.modifierDown, 0), (.modifierUp, 0.5), (.modifierDown, 0.55), (.modifierUp, 0.6)])
        #expect(!fired.contains(true))
    }

    @Test func theDetectorResetsAfterFiring() {
        let fired = run([
            (.modifierDown, 0), (.modifierUp, 0.05), (.modifierDown, 0.1), (.modifierUp, 0.15),
            (.modifierDown, 0.2), (.modifierUp, 0.25),
        ])
        #expect(fired == [false, false, false, true, false, false])
    }
}
