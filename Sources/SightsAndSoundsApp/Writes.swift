import SightsAndSoundsKit
import SwiftUI

/// A write the user asked for, made from a view.
///
/// These used to be `try?`: a delete that failed looked exactly like one
/// that worked, and the only trace was the thing still being there. A
/// failure is now said where the view shows its errors, and logged.
@MainActor
enum Writes {
    /// Run `body`; on failure put "Could not <what>: <why>" into `report`.
    /// Returns whether it worked, for callers that do something after.
    @discardableResult
    static func attempt(_ what: String, report: Binding<String?>, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            let message = "Could not \(what): \(error)"
            AppLog.shared.error("writes", message)
            report.wrappedValue = message
            return false
        }
    }
}

extension View {
    /// For a view with nowhere of its own to show an error.
    func failureAlert(_ failure: Binding<String?>) -> some View {
        alert(
            "That did not work",
            isPresented: Binding(
                get: { failure.wrappedValue != nil },
                set: { if !$0 { failure.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure.wrappedValue ?? "")
        }
    }
}
