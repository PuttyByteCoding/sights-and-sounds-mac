import Foundation

/// Two clean taps of one modifier key — down, up, down, up — inside a
/// short window, with no other key between them. The gesture that flips
/// a keyboard mode from the keyboard, since a modifier tapped on its own
/// is a keystroke nothing else claims.
///
/// Pure: the caller feeds it the events it sees, with their times, and
/// asks whether the second tap just landed. Shift held for a shifted
/// arrow is a down with a key between it and the up, so it never counts;
/// two taps a second apart are two separate first taps.
public struct DoubleTapDetector: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case modifierDown
        case modifierUp
        /// Any other key going down — a chord, not a tap.
        case otherKey
    }

    /// Both taps must finish inside this many seconds of the first down.
    public let window: TimeInterval

    private var firstDown: TimeInterval?
    private var tapsCompleted = 0
    private var chorded = false

    public init(window: TimeInterval = 0.35) {
        self.window = window
    }

    /// Feed one event. Returns true exactly when the second tap's up
    /// completes the gesture; the detector then resets.
    public mutating func feed(_ event: Event, at time: TimeInterval) -> Bool {
        switch event {
        case .otherKey:
            chorded = true
            return false
        case .modifierDown:
            if let firstDown, time - firstDown <= window, tapsCompleted == 1, !chorded {
                return false  // second tap begins
            }
            firstDown = time
            tapsCompleted = 0
            chorded = false
            return false
        case .modifierUp:
            guard let start = firstDown, !chorded, time - start <= window else {
                reset()
                return false
            }
            tapsCompleted += 1
            if tapsCompleted == 2 {
                reset()
                return true
            }
            return false
        }
    }

    private mutating func reset() {
        firstDown = nil
        tapsCompleted = 0
        chorded = false
    }
}
