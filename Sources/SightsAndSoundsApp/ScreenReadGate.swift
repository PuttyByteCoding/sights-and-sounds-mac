import Foundation

/// Which frame read (⇧↓) may still land in the tag field.
///
/// A read takes a moment, and its result belongs to the item it was
/// read from. It used to land on whatever item was showing when it
/// finished — ⏎ then applied a tag read off the previous item's frame —
/// and a second ⇧↓ after the list closed could race the first.
struct ScreenReadGate {
    struct Ticket: Equatable {
        let id = UUID()
        let itemID: UUID?
    }

    private var current: Ticket?

    var isReading: Bool { current != nil }

    /// A new read; any older one in flight is superseded.
    mutating func begin(for itemID: UUID?) -> Ticket {
        let ticket = Ticket(itemID: itemID)
        current = ticket
        return ticket
    }

    /// Whether a finished read may be shown: it is the latest one, it
    /// was not cancelled, and its item is still the one showing.
    func accepts(_ ticket: Ticket, showing itemID: UUID?) -> Bool {
        current == ticket && ticket.itemID == itemID
    }

    /// The read has finished, shown or not.
    mutating func settle(_ ticket: Ticket) {
        if current == ticket { current = nil }
    }

    /// The list closed or the item changed: nothing in flight may land.
    mutating func cancel() { current = nil }
}
