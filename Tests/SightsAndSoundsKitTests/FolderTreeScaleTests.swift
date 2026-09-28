import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The tree is rebuilt on every counts refresh. Finding each node's
/// children by scanning every folder path made that quadratic — around
/// 10⁸ prefix checks for 10,000 folders. A big library must build in a
/// blink; the bound here is generous, the old build took minutes.
@Suite struct FolderTreeScaleTests {
    @Test func twentyThousandFoldersBuildQuickly() {
        var rows: [(path: String, count: Int)] = []
        for band in 0..<200 {
            for show in 0..<100 {
                rows.append(("band-\(band)/show-\(show)", 1))
            }
        }
        let clock = ContinuousClock()
        var tree: [FolderNode] = []
        let elapsed = clock.measure { tree = FolderTreeBuilder.build(from: rows) }

        #expect(elapsed < .seconds(3), "built in \(elapsed)")
        #expect(tree.count == 200)
        #expect(tree.reduce(0) { $0 + $1.subtreeCount } == 20_000)
        #expect(tree.first?.children.count == 100)
    }
}
