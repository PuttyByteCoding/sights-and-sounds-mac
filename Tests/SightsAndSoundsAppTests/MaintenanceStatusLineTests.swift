import SwiftUI
import Testing

@testable import SightsAndSoundsApp

/// Review, Operations, Organise and Maintenance each kept a `status`
/// string and an `errorText` string, in two places, and Operations wrote
/// a failed enqueue into the amber one. One state, so a failure cannot be
/// painted as a notice; and one gate, so an empty state is never drawn
/// before the first read has landed.
@Suite struct MaintenanceStatusLineTests {
    @Test func anErrorIsRedAndANoticeIsAmber() {
        let notice = StatusLineState.notice("Queued — follow it in Background Tasks")
        let error = StatusLineState.error("Could not queue: disk full")
        #expect(!notice.isError && error.isError)
        #expect(notice.color == Theme.Accent.amber)
        #expect(error.color == Theme.Status.redBright)
        #expect(notice.text == "Queued — follow it in Background Tasks")
        #expect(error.text == "Could not queue: disk full")
    }

    @Test func anOptionalStringMapsToAStateOnlyWhenPresent() {
        let none: String? = nil
        #expect(none.map { StatusLineState.error($0) } == nil)
        #expect(Optional("gone").map { StatusLineState.error($0) } == .error("gone"))
    }

    /// Before the first read lands, nothing is empty — it is unknown.
    @Test func theEmptyStateWaitsForTheFirstRead() {
        var read = FirstRead()
        #expect(!read.landed)
        #expect(!read.showsEmpty(true), "drew the empty state before anything had been read")
        read.land()
        #expect(read.landed)
        #expect(read.showsEmpty(true))
        #expect(!read.showsEmpty(false))
    }

    /// Landing is one-way: a later reload cannot send a window back to
    /// its placeholder.
    @Test func aReadStaysLanded() {
        var read = FirstRead()
        read.land()
        read.land()
        #expect(read.landed)
    }
}
