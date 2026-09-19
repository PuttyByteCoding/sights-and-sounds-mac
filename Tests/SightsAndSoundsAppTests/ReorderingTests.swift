import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// The one drop rule the Search String tab's parts and rules share:
/// the dragged row lands before the row it was dropped on, or last.
@Suite struct ReorderingTests {
    private let a = SearchRule(kind: .exclude("a"))
    private let b = SearchRule(kind: .exclude("b"))
    private let c = SearchRule(kind: .exclude("c"))

    @Test func aRowLandsBeforeTheRowItWasDroppedOn() {
        #expect([a, b, c].moving(c.id, before: a.id).map(\.id) == [c.id, a.id, b.id])
        #expect([a, b, c].moving(a.id, before: c.id).map(\.id) == [b.id, a.id, c.id])
    }

    @Test func noTargetOrAnUnknownTargetMeansLast() {
        #expect([a, b, c].moving(a.id, before: nil).map(\.id) == [b.id, c.id, a.id])
        #expect([a, b, c].moving(b.id, before: UUID()).map(\.id) == [a.id, c.id, b.id])
    }

    @Test func droppingARowOnItselfOrAnUnknownRowChangesNothing() {
        #expect([a, b, c].moving(b.id, before: b.id).map(\.id) == [a.id, b.id, c.id])
        #expect([a, b, c].moving(UUID(), before: a.id).map(\.id) == [a.id, b.id, c.id])
    }
}
