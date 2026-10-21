import SwiftUI

/// What a window has to say about the last thing it did: a notice ("Queued
/// — follow it in Background Tasks") or an error.
///
/// One type, so a failure can never be painted in the notice colour. Four
/// windows (Review, Operations, Organise, Maintenance) used to keep a
/// `status` string and an `errorText` string side by side, and one of them
/// wrote a failed enqueue into `status` — amber, the same as "Queued".
enum StatusLineState: Equatable {
    /// Something happened, and it was what was asked for.
    case notice(String)
    /// Something did not happen, or not all of it.
    case error(String)

    var text: String {
        switch self {
        case .notice(let text), .error(let text): text
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var color: Color {
        switch self {
        case .notice: Theme.Accent.amber
        case .error: Theme.Status.redBright
        }
    }
}

/// The one place in a window's footer where its status is read.
///
/// Red for an error, amber for a notice, and the full text in the tooltip
/// because a footer gives a long failure one line.
struct StatusLine: View {
    let state: StatusLineState?

    init(_ state: StatusLineState?) {
        self.state = state
    }

    var body: some View {
        if let state {
            Text(state.text)
                .font(Theme.ui(Theme.TypeScale.secondary))
                .foregroundStyle(state.color)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(state.text)
                .accessibilityLabel(state.isError ? "Error: \(state.text)" : state.text)
        }
    }
}

/// Whether a window has heard from the library yet.
///
/// Review, Maintenance, Organise and Operations each drew their empty
/// state ("No pending duplicates", "No Findings", "No Moves Yet", every
/// operation "unavailable for this selection") until the first read
/// returned — on a large library over a slow drive, a visible lie for a
/// moment. The empty state is only an answer once there has been a read.
struct FirstRead {
    private(set) var landed = false

    /// The first read has returned — with an answer or a failure; either
    /// way, what is on screen is no longer a guess.
    mutating func land() { landed = true }

    /// The empty state shows only once a read has landed and found
    /// nothing. Before that, nothing (or a quiet placeholder).
    func showsEmpty(_ isEmpty: Bool) -> Bool { landed && isEmpty }
}

/// The quiet placeholder a window shows before its first read lands.
struct FirstReadPlaceholder: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
