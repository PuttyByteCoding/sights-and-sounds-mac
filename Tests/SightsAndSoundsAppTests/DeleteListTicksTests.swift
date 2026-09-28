import Foundation
import Testing

@testable import SightsAndSoundsApp

/// The delete list's ticks are the purge's selection. A reload after a
/// restore or a purge must never tick a file the operator unticked —
/// that turned "Restore 3" into "Delete 7" of the files deliberately
/// kept back.
@Suite struct DeleteListTicksTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func theFirstLoadTicksEverything() {
        var ticks = DeleteListTicks()
        ticks.listLoaded([a, b, c])
        #expect(ticks.ticked == [a, b, c])
    }

    @Test func aRestoreOfTheTickedFilesLeavesTheUntickedOnesUnticked() {
        var ticks = DeleteListTicks()
        ticks.listLoaded([a, b, c, d])
        ticks.toggle(c)
        ticks.toggle(d)
        // Restore Selected takes a and b off the list.
        ticks.clear()
        ticks.listLoaded([c, d])
        #expect(ticks.ticked.isEmpty)
    }

    @Test func untickingEverythingStaysUnticked() {
        var ticks = DeleteListTicks()
        ticks.listLoaded([a, b])
        ticks.toggle(a)
        ticks.toggle(b)
        ticks.listLoaded([a, b])
        #expect(ticks.ticked.isEmpty)
    }

    @Test func aFileMarkedElsewhereArrivesTicked() {
        var ticks = DeleteListTicks()
        ticks.listLoaded([a, b])
        ticks.toggle(b)
        ticks.listLoaded([a, b, c])
        #expect(ticks.ticked == [a, c])
    }

    @Test func aFileThatLeftAndCameBackIsTickedAgain() {
        var ticks = DeleteListTicks()
        ticks.listLoaded([a, b])
        ticks.toggle(b)
        ticks.listLoaded([a])
        ticks.listLoaded([a, b])
        #expect(ticks.ticked == [a, b])
    }
}
