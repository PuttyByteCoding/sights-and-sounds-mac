import Foundation
import Testing

@testable import SightsAndSoundsApp

/// A frame read (⇧↓) takes a moment. Its result belongs to the item it
/// was read from: it used to land on whatever item was showing when it
/// finished, so ⏎ applied a tag read off the PREVIOUS item's frame.
@Suite struct ScreenReadGateTests {
    @Test func aReadForTheShownItemIsAccepted() {
        var gate = ScreenReadGate()
        let item = UUID()
        let ticket = gate.begin(for: item)
        #expect(gate.accepts(ticket, showing: item))
    }

    @Test func aReadThatFinishesAfterTheItemChangedIsDropped() {
        var gate = ScreenReadGate()
        let first = UUID(), second = UUID()
        let ticket = gate.begin(for: first)
        gate.cancel()  // the list closes as the item changes
        #expect(!gate.accepts(ticket, showing: second))
        #expect(!gate.accepts(ticket, showing: first))
    }

    @Test func aNewerReadSupersedesAnOlderOne() {
        var gate = ScreenReadGate()
        let item = UUID()
        let older = gate.begin(for: item)
        let newer = gate.begin(for: item)
        #expect(!gate.accepts(older, showing: item))
        #expect(gate.accepts(newer, showing: item))
    }

    @Test func aReadInFlightBlocksAnotherUntilItSettles() {
        var gate = ScreenReadGate()
        let item = UUID()
        let ticket = gate.begin(for: item)
        #expect(gate.isReading)
        gate.settle(ticket)
        #expect(!gate.isReading)
    }
}
