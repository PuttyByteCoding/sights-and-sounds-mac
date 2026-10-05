import AVFoundation
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp

/// A player over a service that behaves the way a library on another
/// Mac can: an answer fails, an older answer arrives after a newer one,
/// and the window closes while the library goes on changing.
@Suite(.writesVideo) @MainActor struct PlayerModelServiceTests {
    struct Fixture {
        let library: LibraryDatabase
        let stub: StubLibraryService
        let root: URL
        let a: MediaItem
        let b: MediaItem
        let unmounted: MediaItem
        let tag: SightsAndSoundsKit.Tag
        let band: TagCategory

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("player-service-\(UUID().uuidString)", isDirectory: true)
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "PlayerService")
            let online = Source(name: "Here", rootPath: root.path)
            let away = Source(name: "Away", rootPath: root.appendingPathComponent("not-mounted").path)
            try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("a.mp4"), seconds: 4, variant: 0)
            try await DemoMediaFactory.writeVideo(to: root.appendingPathComponent("b.mp4"), seconds: 4, variant: 1)
            let band = TagCategory(name: "Band")
            let tag = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Alpha")
            let a = MediaItem(
                sourceID: online.id, kind: .video, relativePath: "a.mp4", durationSeconds: 4, needsReview: false)
            let b = MediaItem(
                sourceID: online.id, kind: .video, relativePath: "b.mp4", durationSeconds: 4, needsReview: false)
            let unmounted = MediaItem(
                sourceID: away.id, kind: .video, relativePath: "c.mp4", durationSeconds: 4, needsReview: false)
            try await library.writer.write { db in
                try online.insert(db)
                try away.insert(db)
                try band.insert(db)
                try tag.insert(db)
                for item in [a, b, unmounted] { try item.insert(db) }
            }
            self.library = library
            self.a = a
            self.b = b
            self.unmounted = unmounted
            self.tag = tag
            self.band = band
            stub = StubLibraryService(LocalLibraryService(library: library))
        }

        func tearDown() { try? FileManager.default.removeItem(at: root) }

        @MainActor func player(_ playlist: [MediaItem]) -> PlayerModel {
            PlayerModel(
                request: PlayerRequest(
                    libraryID: UUID(), itemID: playlist[0].id, playlist: playlist.map(\.id), name: "Test"),
                library: library, appDatabase: nil, service: stub)
        }
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition(), "\(what): never happened")
    }

    @Test func aFailedLoadLetsGoOfTheItemAndSaysWhy() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("the first item") { model.fileURL != nil }

        f.stub.fail("opened(itemID:)")
        model.load(itemID: f.b.id)

        try await waitUntil("the error") { model.loadError != nil }
        #expect(model.item == nil, "the last item is still the one keys act on")
        #expect(model.fileURL == nil)
        #expect(model.loadError?.contains("opened") == true)
    }

    @Test func anItemWithNoPlaybackURLShowsWhyAndStopsTheLast() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.unmounted])
        defer { model.shutdown() }
        try await waitUntil("the first item") { model.fileURL != nil }

        model.load(itemID: f.unmounted.id)

        try await waitUntil("the error") { model.loadError != nil }
        #expect(model.item?.id == f.unmounted.id)
        #expect(model.fileURL == nil)
    }

    /// Stepped to b and straight back to a, with b's answer held up:
    /// the answer to the step no longer wanted must not land on top.
    @Test func aSlowOlderLoadDoesNotReplaceANewerOne() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("the first item") { model.item?.id == f.a.id }
        let before = f.stub.answered("opened(itemID:)")

        f.stub.delay("opened(itemID:)", by: .milliseconds(400))
        model.load(itemID: f.b.id)
        try await waitUntil("b was asked for") { f.stub.calls("opened(itemID:)") == before + 1 }
        model.load(itemID: f.a.id)
        try await waitUntil("both answered") { f.stub.answered("opened(itemID:)") == before + 2 }
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.item?.id == f.a.id)
    }

    @Test func theOpeningQueueIsTheItemsNamedInTheirOrder() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.b, f.a])
        defer { model.shutdown() }
        try await waitUntil("the queue") { model.queue.items.count == 2 }
        #expect(model.queue.items.map(\.id) == [f.b.id, f.a.id])
    }

    @Test func aRefreshThatFailsSaysSoAndKeepsTheQueue() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("the queue") { model.queue.items.count == 2 }

        f.stub.fail("queueItems(_:)")
        model.refreshQueue()

        try await waitUntil("the error") { model.loadError?.hasPrefix("Refresh failed") == true }
        #expect(model.queue.items.count == 2)
    }

    @Test func aTagAppliedElsewhereReachesThePlayer() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("the first item") { model.item?.id == f.a.id }
        #expect(!model.hasTag(f.tag.id))

        try f.library.assignTag(f.tag.id, to: [f.a.id])

        try await waitUntil("the tag") { model.hasTag(f.tag.id) }
    }

    @Test func closingThePlayerEndsItsSubscription() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        try await waitUntil("the first item") { model.item?.id == f.a.id }
        #expect(f.stub.openChangeStreams == 1)

        model.shutdown()

        try await waitUntil("the stream was let go of") { f.stub.openChangeStreams == 0 }
    }

    // MARK: - The panels

    private func settled(_ model: PlayerModel) async throws {
        try await waitUntil("the player settled") { model.isSettled }
    }

    /// The item and its panel arrive together: the moment the next item
    /// is the one on screen, the tags drawn are its own. Asked for after
    /// the item had been set, there was a moment when a click on the
    /// panel edited the last item's tags under the new one's name.
    @Test func aNewItemArrivesWithItsOwnPanel() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try f.library.assignTag(f.tag.id, to: [f.a.id])
        _ = try f.library.createEmbeddedClip(parentID: f.a.id, name: "Song", startSeconds: 1, endSeconds: 2)
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("a, tagged, with its segment") {
            model.item?.id == f.a.id && model.hasTag(f.tag.id) && model.segments.count == 1
        }

        model.load(itemID: f.b.id)
        var sawTheLastItemsPanel = false
        for _ in 0..<400 where model.item?.id != f.b.id {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Checked in the same turn the item was seen to change.
        if model.item?.id == f.b.id, model.hasTag(f.tag.id) || !model.segments.isEmpty {
            sawTheLastItemsPanel = true
        }
        #expect(model.item?.id == f.b.id)
        #expect(!sawTheLastItemsPanel)
    }

    /// The panel is re-read for a (a change elsewhere), the answer is
    /// slow, and meanwhile the player has stepped to b.
    @Test func anAnswerForTheLastItemIsNotShownUnderTheNext() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try f.library.assignTag(f.tag.id, to: [f.a.id])
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("a, tagged") { model.item?.id == f.a.id && model.hasTag(f.tag.id) }
        try await settled(model)

        f.stub.holdAnswer("tagging(itemID:)", by: .milliseconds(400))
        f.stub.holdAnswer("segments(parentID:)", by: .milliseconds(400))
        model.refreshTagging()
        model.refreshSegments()
        model.load(itemID: f.b.id)
        try await waitUntil("b") { model.item?.id == f.b.id }
        try await settled(model)

        #expect(!model.hasTag(f.tag.id), "a's tags are drawn under b")
        #expect(model.itemTags.flatMap(\.tags).isEmpty)
    }

    /// Tagged and untagged at once. The read after the first press is
    /// answered late, with what was true then; the read after the second
    /// has already said the tag is off, and must not be overruled.
    @Test func aLateOlderTagReadDoesNotUndoANewerOne() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a") { model.item?.id == f.a.id }
        try await settled(model)

        f.stub.holdAnswer("itemTags(itemID:)", by: .milliseconds(400))
        model.toggleTag(f.tag.id)   // on; its read is held
        try await waitUntil("the first read was made") { f.stub.calls("itemTags(itemID:)") >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        model.toggleTag(f.tag.id)   // off; its read is answered at once
        try await settled(model)

        #expect(!model.hasTag(f.tag.id))
    }

    @Test func aFailedPanelReadSaysSoAndKeepsWhatIsShown() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try f.library.assignTag(f.tag.id, to: [f.a.id])
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a, tagged") { model.item?.id == f.a.id && model.hasTag(f.tag.id) }
        try await settled(model)

        f.stub.fail("itemTags(itemID:)")
        model.refreshItemTags()
        try await settled(model)

        #expect(model.loadError?.contains("itemTags") == true)
        #expect(model.hasTag(f.tag.id))
    }

    @Test func thePanelFollowsAnEditMadeHere() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a") { model.item?.id == f.a.id }
        try await settled(model)

        model.toggleTag(f.tag.id)
        try await settled(model)
        #expect(model.hasTag(f.tag.id))

        model.openSegmentMark()
        _ = try f.library.createEmbeddedClip(parentID: f.a.id, name: "Song", startSeconds: 1, endSeconds: 2)
        model.refreshSegments()
        try await settled(model)
        #expect(model.segments.map(\.name) == ["Song"])
        #expect(model.songCount + model.clipCount == 1)
    }

    @Test func historyAndSearchAreReadForTheItemShowing() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("a") { model.item?.id == f.a.id }

        model.refreshHistory()
        model.refreshSearch()
        try await settled(model)
        #expect(model.historyRows.map(\.id) == [f.a.id], "a load is a watch")
        #expect(model.searchSubject?.fileName == "a.mp4")

        // The search values never name the last item under the next.
        model.load(itemID: f.b.id)
        try await waitUntil("b") { model.item?.id == f.b.id }
        #expect(model.searchSubject?.fileName != "a.mp4")
        model.refreshSearch()
        try await settled(model)
        #expect(model.searchSubject?.fileName == "b.mp4")
    }

    // MARK: - Playback history and flags

    private func row(_ f: Fixture, _ item: MediaItem) throws -> MediaItem {
        try #require(try f.library.writer.read { try MediaItem.fetchOne($0, key: item.id) })
    }

    /// Where the video stopped is a request on its way when the window
    /// closes. It must still land — and say when it happened, not when
    /// it arrived.
    @Test func closingThePlayerSavesWhereItStopped() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        try await waitUntil("a, playable") { model.fileURL != nil }
        model.seek(to: 2)
        try await waitUntil("the playhead moved") { model.currentSeconds > 0 }
        await WriteQueue.settleAll()
        let before = f.stub.playbackEvents.count

        f.stub.delay("recordPlayback(_:)", by: .milliseconds(300))
        let closed = Date()
        model.shutdown()
        #expect(f.stub.playbackEvents.count == before, "nothing can have landed yet")
        await WriteQueue.settleAll()

        let stops = f.stub.playbackEvents.dropFirst(before)
        guard case .stopped(let itemID, let position, _, let at)? = stops.last else {
            Issue.record("no stop was recorded: \(Array(stops))")
            return
        }
        #expect(itemID == f.a.id)
        #expect(position > 0)
        #expect(abs(at.timeIntervalSince(closed)) < 0.2, "stamped \(at.timeIntervalSince(closed))s from the close")
    }

    @Test func aLoadIsRecordedAsAWatchAndASegmentIsNot() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let segment = try f.library.createEmbeddedClip(
            parentID: f.a.id, name: "Song", startSeconds: 1, endSeconds: 2)
        let model = f.player([f.b, segment])
        defer { model.shutdown() }
        try await waitUntil("b") { model.item?.id == f.b.id }
        await WriteQueue.settleAll()
        #expect(f.stub.playbackEvents.map(\.itemID) == [f.b.id])
        #expect(try row(f, f.b).lastWatchedAt != nil)

        model.load(itemID: segment.id)
        try await waitUntil("the segment") { model.item?.id == segment.id }
        await WriteQueue.settleAll()
        #expect(!f.stub.playbackEvents.contains { $0.itemID == segment.id })
    }

    /// Favourite on, then off, with the first write held up. Sent side
    /// by side the second would land first and the first would then turn
    /// the flag back on.
    @Test func theLastOfTwoFlagPressesWins() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a, playable") { model.fileURL != nil }
        await WriteQueue.settleAll()

        f.stub.delay("setFlag(_:_:itemID:)", by: .milliseconds(300))
        model.perform(.toggleFavorite)
        #expect(model.item?.isFavorite == true, "the mark shows at once")
        model.perform(.toggleFavorite)
        #expect(model.item?.isFavorite == false)
        await WriteQueue.settleAll()
        try await waitUntil("both answers were shown") { f.stub.answered("setFlag(_:_:itemID:)") == 2 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(try row(f, f.a).isFavorite == false)
        #expect(model.item?.isFavorite == false)
    }

    @Test func aFlagThatCannotBeSetSaysSoAndShowsTheRowAsItIs() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a, playable") { model.fileURL != nil }

        f.stub.fail("setFlag(_:_:itemID:)")
        model.perform(.toggleFavorite)
        #expect(model.item?.isFavorite == true, "the mark shows at once")

        try await waitUntil("the error") { model.loadError?.contains("setFlag") == true }
        try await waitUntil("the row as it is") { model.item?.isFavorite == false }
    }

    @Test func aMarkThatMovesTheFileLeavesThePlayerNamingItsNewPath() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a, playable") { model.fileURL != nil }

        model.perform(.toggleMarkedForDeletion)

        try await waitUntil("the new path") { model.fileURL?.path.hasSuffix("_ToDelete/a.mp4") == true }
        #expect(model.item?.markedForDeletion == true)
    }

    // MARK: - The tag panel's writes

    private func isTagged(_ f: Fixture, _ item: MediaItem) throws -> Bool {
        try f.library.writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM mediaItemTag WHERE mediaItemID = ? AND tagID = ?",
                arguments: [item.id, f.tag.id]) ?? 0
        } > 0
    }

    /// The key is a toggle. Pressed three times it ends on, however long
    /// the first press takes to land.
    @Test func aBoundKeyPressedThreeTimesEndsOn() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try f.library.setKeyBinding("1", tagID: f.tag.id)
        let model = f.player([f.b])
        defer { model.shutdown() }
        try await waitUntil("b, with its keys") { model.item?.id == f.b.id && model.boundKeys["1"] != nil }
        try await settled(model)

        f.stub.delay("toggleTag(_:on:)", by: .milliseconds(250))
        for _ in 0..<3 { #expect(model.handleBoundKey("1")) }
        #expect(!model.handleBoundKey("9"), "an unbound key is not handled")
        try await settled(model)

        #expect(try isTagged(f, f.b))
        #expect(model.hasTag(f.tag.id))
        #expect(f.stub.calls("toggleTag(_:on:)") == 3)
    }

    /// Tagged, and stepped on before the tag has landed: it belongs to
    /// the item it was pressed on, and the next item's panel does not
    /// show it.
    @Test func aTagAppliedJustBeforeSteppingGoesToTheItemItWasPressedOn() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("a") { model.item?.id == f.a.id }
        try await settled(model)

        f.stub.delay("toggleTag(_:on:)", by: .milliseconds(300))
        model.toggleTag(f.tag.id)
        model.load(itemID: f.b.id)
        try await waitUntil("b") { model.item?.id == f.b.id }
        try await settled(model)

        #expect(try isTagged(f, f.a))
        #expect(try !isTagged(f, f.b))
        #expect(!model.hasTag(f.tag.id), "a's tag is drawn on b")
    }

    /// Taken off, then applied, with the first on its way: it ends on.
    /// Any number of toggles alone would end the same in any order;
    /// these two would not, so this is the one that shows the order is
    /// kept.
    @Test func aTagTakenOffThenAppliedEndsOn() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try f.library.assignTag(f.tag.id, to: [f.a.id])
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a, tagged") { model.item?.id == f.a.id && model.hasTag(f.tag.id) }
        try await settled(model)

        f.stub.delay("toggleTag(_:on:)", by: .milliseconds(300))
        model.toggleTag(f.tag.id)   // off, held up
        model.applyTag(f.tag.id)    // on
        try await settled(model)

        #expect(try isTagged(f, f.a), "the apply overtook the toggle it followed")
        #expect(model.hasTag(f.tag.id))
    }

    @Test func anAdvancingKeyStepsOnceItsTagIsOnAndNotWhenItTookItOff() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        try f.library.setKeyBinding("1", tagID: f.tag.id, advance: true)
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("a, with its keys") { model.item?.id == f.a.id && model.boundKeys["1"] != nil }
        try await settled(model)

        #expect(model.handleBoundKey("1"))
        try await waitUntil("stepped to b") { model.item?.id == f.b.id }
        try await settled(model)
        #expect(try isTagged(f, f.a))

        // Back on a, which wears the tag: the key takes it off and stays.
        model.load(itemID: f.a.id)
        try await waitUntil("a again") { model.item?.id == f.a.id && model.hasTag(f.tag.id) }
        try await settled(model)
        #expect(model.handleBoundKey("1"))
        try await settled(model)
        #expect(try !isTagged(f, f.a))
        #expect(model.item?.id == f.a.id)
    }

    @Test func aTagWriteThatFailsSaysSo() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a") { model.item?.id == f.a.id }
        try await settled(model)

        f.stub.fail("toggleTag(_:on:)")
        model.toggleTag(f.tag.id)
        try await settled(model)

        #expect(model.loadError?.contains("toggleTag") == true)
        #expect(!model.hasTag(f.tag.id))
    }

    @Test func aTagAddedByNameIsMadeAppliedAndInThePanel() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a") { model.item?.id == f.a.id }
        try await settled(model)

        model.addTag(named: "Gamma", categoryID: f.band.id)
        try await settled(model)

        let gamma = try #require(model.panelVocabulary.flatMap(\.tags).first { $0.name == "Gamma" })
        #expect(model.hasTag(gamma.id))
        #expect(model.tagSearchIndex.contains { $0.tag.id == gamma.id })

        model.renameTag(gamma.id, to: "Gamma Ray")
        model.addAlias("GR", to: gamma.id)
        model.applyTag(f.tag.id)
        try await settled(model)
        #expect(model.panelVocabulary.flatMap(\.tags).contains { $0.name == "Gamma Ray" })
        #expect(model.hasTag(f.tag.id))
        #expect(model.recentlyAppliedTagIDs.first == f.tag.id)
    }

    /// The editor binds a key and moves to the next free one, which it
    /// finds on the model: the bindings there are current when the call
    /// returns.
    @Test func aKeyBindingIsOnTheModelWhenTheCallReturns() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a") { model.item?.id == f.a.id }
        try await settled(model)

        #expect(await model.setKeyBinding("2", tagID: f.tag.id, advance: true) == nil)
        #expect(model.boundKeys["2"]?.tagID == f.tag.id)
        #expect(model.boundKeys["2"]?.advance == true)

        #expect(await model.removeKeyBinding("2") == nil)
        #expect(model.boundKeys["2"] == nil)

        f.stub.fail("setKeyBinding(_:tagID:advance:)")
        let problem = await model.setKeyBinding("3", tagID: f.tag.id, advance: false)
        #expect(problem?.contains("setKeyBinding") == true)
        #expect(model.boundKeys["3"] == nil)
    }

    // MARK: - Marks made while playing

    /// Play far enough into the item for a mark to have a length.
    private func playhead(_ model: PlayerModel, at seconds: Double) async throws {
        model.seek(to: seconds)
        try await waitUntil("the playhead at \(seconds)") { abs(model.currentSeconds - seconds) < 0.4 }
    }

    /// Marked on a, closed, and stepped on before the segment had been
    /// made: it is a's segment, and b's rail does not show it.
    @Test func aMarkClosedJustBeforeSteppingBelongsToTheVideoItWasMarkedOn() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a, f.b])
        defer { model.shutdown() }
        try await waitUntil("a, playable") { model.item?.id == f.a.id && model.fileURL != nil }
        try await playhead(model, at: 1)
        model.openSegmentMark()
        try await playhead(model, at: 2.5)

        f.stub.delay("createSegment(parentID:name:startSeconds:endSeconds:role:)", by: .milliseconds(300))
        model.closeSegmentMark(as: .song)
        #expect(model.pendingSegmentStart == nil, "the mark is closed at the press")
        model.load(itemID: f.b.id)
        try await waitUntil("b") { model.item?.id == f.b.id }
        try await settled(model)

        let made = try f.library.clips(of: f.a.id)
        #expect(made.count == 1)
        #expect(made.first?.segmentRole == .song)
        #expect(abs((made.first?.clipStartSeconds ?? 0) - 1) < 0.4)
        #expect(try f.library.clips(of: f.b.id).isEmpty)
        #expect(model.segments.isEmpty, "a's segment is on b's rail")
        #expect(model.selectedSegmentID == nil)
    }

    @Test func aClosedMarkIsOnTheRailAndSelected() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a, playable") { model.item?.id == f.a.id && model.fileURL != nil }
        try await playhead(model, at: 1)
        model.openSegmentMark()
        try await playhead(model, at: 2.5)

        model.closeSegmentMark(as: .clip)
        try await settled(model)

        #expect(model.segments.count == 1 && model.clipCount == 1)
        #expect(model.selectedSegmentID == model.segments.first?.id)
    }

    /// The range just marked is the thing not to lose: a mark that could
    /// not be saved is open again, where it was.
    @Test func aMarkThatCannotBeSavedIsStillOpen() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a, playable") { model.item?.id == f.a.id && model.fileURL != nil }
        try await playhead(model, at: 1)
        model.openSegmentMark()
        let start = try #require(model.pendingSegmentStart)
        try await playhead(model, at: 2.5)

        f.stub.fail("createSegment(parentID:name:startSeconds:endSeconds:role:)")
        model.closeSegmentMark(as: .song)
        try await settled(model)

        #expect(model.loadError?.contains("createSegment") == true)
        #expect(model.pendingSegmentStart == start)
        #expect(model.segments.isEmpty)
    }

    @Test func aBlockTappedOpenAndClosedIsOnTheRail() async throws {
        let f = try await Fixture()
        defer { f.tearDown() }
        let model = f.player([f.a])
        defer { model.shutdown() }
        try await waitUntil("a, playable") { model.item?.id == f.a.id && model.fileURL != nil }
        try await playhead(model, at: 1)
        model.blockTap(open: true)
        try await playhead(model, at: 2.5)

        model.blockTap(open: false)
        #expect(model.pendingBlockStart == nil)
        try await settled(model)

        #expect(model.hideBlocks.count == 1)
        #expect(abs((model.hideBlocks.first?.startSeconds ?? 0) - 1) < 0.4)
        #expect(try f.library.blocks(of: f.a.id).count == 1)
    }
}

extension PlaybackEvent {
    var itemID: UUID {
        switch self {
        case .started(let id, _), .stopped(let id, _, _, _), .completed(let id, _): id
        }
    }
}
