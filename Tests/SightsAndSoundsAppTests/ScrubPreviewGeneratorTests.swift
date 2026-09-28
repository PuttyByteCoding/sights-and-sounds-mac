import Foundation
import Testing

@testable import SightsAndSoundsApp

/// Every hovered item's generator holds an open asset — and the file
/// under it, which can stop a drive ejecting. They used to be kept for
/// the life of the app (released only for the last item at shutdown);
/// only the most recently hovered few may stay open.
@Suite struct ScrubPreviewGeneratorTests {
    @Test func onlyTheMostRecentGeneratorsStayOpen() async {
        let provider = ScrubPreviewProvider()
        for n in 0..<8 {
            _ = await provider.preview(
                itemID: UUID(),
                fileURL: URL(fileURLWithPath: "/tmp/sas-no-such-file-\(n).mp4"),
                atSeconds: 0)
        }
        #expect(await provider.openGeneratorCount <= ScrubPreviewProvider.openGeneratorLimit)
    }

    @Test func theItemBeingHoveredKeepsItsGenerator() async {
        let provider = ScrubPreviewProvider()
        let current = UUID()
        let url = URL(fileURLWithPath: "/tmp/sas-no-such-file-current.mp4")
        for n in 0..<8 {
            _ = await provider.preview(itemID: current, fileURL: url, atSeconds: Double(n) * 10)
            _ = await provider.preview(
                itemID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/sas-other-\(n).mp4"), atSeconds: 0)
        }
        #expect(await provider.hasGenerator(for: current))
    }
}
