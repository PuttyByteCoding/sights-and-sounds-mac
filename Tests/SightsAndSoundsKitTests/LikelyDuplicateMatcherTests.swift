import Foundation
import GRDB
import Testing

@testable import SightsAndSoundsKit

/// The cheap duplicate check: names that differ only by a copy marker,
/// and files of the same size and running time under any name.
@Suite struct LikelyDuplicateMatcherTests {
    typealias M = LikelyDuplicateMatcher

    /// A settings file written before the two switches existed loads with
    /// fingerprint matching off and the cheap check on.
    @Test func theDuplicateSwitchesDefaultFingerprintsOffAndNamesOn() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!old.fingerprintMatching)
        #expect(old.likelyDuplicateMatching)
        let set = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"fingerprintMatching": true, "likelyDuplicateMatching": false}"#.utf8))
        #expect(set.fingerprintMatching && !set.likelyDuplicateMatching)
    }

    @Test func copyMarkersComeOffTheEnd() {
        #expect(M.stem(of: "Show.mp4") == M.Stem(text: "show", hadMarker: false))
        for name in [
            "Show copy.mp4", "Show copy 2.mp4", "Show - Copy.mp4", "Show - Copy (2).mp4",
            "Show (1).mp4", "Show(3).mov", "Show [2].mkv", "Show_copy.mp4", "Show (1) copy.mp4",
            "Show copy\\.mp4", "SHOW Copy.avi",
        ] {
            #expect(M.stem(of: name) == M.Stem(text: "show", hadMarker: true), "\(name)")
        }
    }

    /// A word that ends in "copy", or a series number, is part of the name.
    @Test func namesThatOnlyLookLikeCopiesKeepTheirEnds() {
        #expect(M.stem(of: "Photocopy.mp4") == M.Stem(text: "photocopy", hadMarker: false))
        #expect(M.stem(of: "Lesson 2.mp4") == M.Stem(text: "lesson 2", hadMarker: false))
        #expect(M.stem(of: "(1).mp4").text == "(1)", "a marker is never the whole name")
    }

    private func file(_ name: String, size: Int64 = 5_000_000, duration: Double? = 600) -> M.File {
        M.File(id: UUID(), fileName: name, fileSize: size, durationSeconds: duration)
    }

    @Test func aCopyBesideItsOriginalIsPairedAndEvidenceRaisesTheConfidence() throws {
        let original = file("Show.mp4")
        let sameEverything = file("Show copy.mp4")
        let reencoded = file("Show (1).mkv", size: 2_000_000, duration: 600.4)
        let unrelated = file("Show (2).mp4", size: 1_000, duration: 12)
        let pairs = M.pairs(in: [original, sameEverything, reencoded, unrelated])

        func pair(_ x: M.File, _ y: M.File) -> M.Pair? {
            pairs.first { Set([$0.a, $0.b]) == Set([x.id, y.id]) }
        }
        let exact = try #require(pair(original, sameEverything))
        #expect(exact.source == .similarName)
        #expect(exact.confidence > 0.9)
        let lengthOnly = try #require(pair(original, reencoded))
        #expect(lengthOnly.confidence == 0.75)
        // A marked name beside its unmarked original is a pair even with
        // nothing else in common, at the lowest confidence.
        #expect(pair(original, unrelated)?.confidence == 0.5)
        // Two marked names need evidence: (1) and (2) here share none.
        #expect(pair(reencoded, unrelated) == nil)
    }

    @Test func aNumberedSeriesIsNotACopy() {
        let pairs = M.pairs(in: [
            file("Lesson (1).mp4", size: 3_000_000, duration: 300),
            file("Lesson (2).mp4", size: 4_000_000, duration: 420),
            file("Lesson (3).mp4", size: 5_000_000, duration: 515),
        ])
        #expect(pairs.isEmpty)
    }

    @Test func sameSizeAndLengthUnderDifferentNamesIsAPair() {
        let a = file("2019-07-04 fireworks.mov", size: 812_345_678, duration: 1_200)
        let b = file("IMG_4410.mov", size: 812_345_678, duration: 1_200.2)
        let differentLength = file("other.mov", size: 812_345_678, duration: 900)
        let small = file("blip.wav", size: 4_000, duration: 1)
        let smallTwin = file("blap.wav", size: 4_000, duration: 1)
        let pairs = M.pairs(in: [a, b, differentLength, small, smallTwin])
        #expect(pairs.count == 1)
        #expect(Set([pairs[0].a, pairs[0].b]) == Set([a.id, b.id]))
        #expect(pairs[0].source == .sizeAndLength)
    }

    @Test func aPairThatMatchesBothWaysIsReportedOnce() {
        let pairs = M.pairs(in: [file("Show.mp4"), file("Show copy.mp4")])
        #expect(pairs.count == 1)
        #expect(pairs.first?.source == .similarName)
    }

    /// The job: pairs become pending candidates, once, and a file already
    /// on the delete list is left out.
    @Test func theSweepFlagsEachPairOnce() async throws {
        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Likely")
        let source = Source(name: "Root", rootPath: "/tmp/likely-\(UUID().uuidString)")
        func item(_ path: String, marked: Bool = false) -> MediaItem {
            MediaItem(
                sourceID: source.id, kind: .video, relativePath: path, fileSize: 9_000_000,
                durationSeconds: 60, markedForDeletion: marked)
        }
        let original = item("set/Show.mp4")
        let copy = item("set/Show copy.mp4")
        let gone = item("set/Show (1).mp4", marked: true)
        try await library.writer.write { db in
            try source.insert(db)
            for row in [original, copy, gone] { try row.insert(db) }
        }
        let runner = JobRunner(library: library)
        _ = try await runner.enqueue(LikelyDuplicateSweepJob.self)
        _ = try await runner.enqueue(LikelyDuplicateSweepJob.self)
        try await runner.runPending()

        let candidates = try await library.read { try DuplicateCandidate.fetchAll($0) }
        #expect(candidates.count == 1)
        #expect(Set([candidates[0].itemAID, candidates[0].itemBID]) == Set([original.id, copy.id]))
        #expect(candidates[0].status == .pending)
    }
}
