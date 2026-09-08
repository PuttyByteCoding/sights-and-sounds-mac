import Foundation
import Testing
import UniformTypeIdentifiers

@testable import SightsAndSoundsApp

/// The dragged row's payload round-trips through the system type the
/// drop targets match on.
@Suite struct PanelRowDragTests {
    @Test func theIdRoundTripsAsPlainData() async throws {
        guard #available(macOS 15.2, *) else { return }
        let payload = PanelRowDrag(id: UUID())
        let data = try await payload.exported(as: .data)
        let back = try await PanelRowDrag(importing: data, contentType: .data)
        #expect(back == payload)
    }

    @Test func garbageIsRefused() async throws {
        guard #available(macOS 15.2, *) else { return }
        await #expect(throws: (any Error).self) {
            _ = try await PanelRowDrag(importing: Data("not a uuid".utf8), contentType: .data)
        }
    }
}
