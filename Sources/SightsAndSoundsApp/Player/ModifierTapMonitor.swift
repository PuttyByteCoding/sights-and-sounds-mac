import AppKit
import SwiftUI
import SightsAndSoundsKit

/// Watches one window for a modifier double-tapped on its own — ⇧⇧,
/// ⌃⌃ — and reports it. A local event monitor scoped to the hosting
/// window, installed for the time this view is in one, the way the
/// Live Text click monitor is; flag changes never reach `onKeyPress`,
/// so this is the only way to hear a modifier by itself.
struct ModifierTapMonitor: NSViewRepresentable {
    enum Modifier: Hashable, CaseIterable {
        case shift, control, option, command

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .shift: .shift
            case .control: .control
            case .option: .option
            case .command: .command
            }
        }
    }

    /// Which modifiers to listen for, and what each double-tap does.
    let taps: [Modifier: () -> Void]

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.taps = taps
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.taps = taps
    }

    final class MonitorView: NSView {
        var taps: [Modifier: () -> Void] = [:]
        private var monitor: Any?
        private var detectors: [Modifier: DoubleTapDetector] = [:]
        private var held: Set<Modifier> = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                self?.observe(event)
                return event
            }
        }

        private func observe(_ event: NSEvent) {
            guard event.window === window else { return }
            let time = event.timestamp
            if event.type == .keyDown {
                for modifier in taps.keys {
                    _ = detectors[modifier, default: DoubleTapDetector()].feed(.otherKey, at: time)
                }
                return
            }
            let now = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            for (modifier, action) in taps {
                let down = now.contains(modifier.flag)
                let was = held.contains(modifier)
                guard down != was else { continue }
                if down { held.insert(modifier) } else { held.remove(modifier) }
                // A second modifier alongside is a chord, not a tap.
                let others = Modifier.allCases.filter { $0 != modifier && now.contains($0.flag) }
                if !others.isEmpty {
                    _ = detectors[modifier, default: DoubleTapDetector()].feed(.otherKey, at: time)
                    continue
                }
                if detectors[modifier, default: DoubleTapDetector()].feed(
                    down ? .modifierDown : .modifierUp, at: time
                ) {
                    action()
                }
            }
        }
    }
}
