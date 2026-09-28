import Foundation

/// What VoiceOver hears from the transport. Its buttons are icons with
/// only a tooltip, and the scrubber was a drawing with no element at
/// all, so neither could be found or used without sight.
enum TransportAccessibility {
    /// A tooltip as a spoken label: without the trailing key hint —
    /// "Unmute (M)" reads "Unmute", not "Unmute M".
    static func label(fromHelp help: String) -> String {
        guard help.hasSuffix(")"), let open = help.range(of: " (", options: .backwards) else { return help }
        return String(help[..<open.lowerBound])
    }

    /// The scrubber's value: where, of how long.
    static func position(current: Double, duration: Double) -> String {
        guard duration > 0 else { return TransportBarTime.format(current) }
        return "\(TransportBarTime.format(current)) of \(TransportBarTime.format(duration))"
    }

    /// How far VoiceOver's increment and decrement move the playhead.
    static let adjustSeconds: Double = 10
}
