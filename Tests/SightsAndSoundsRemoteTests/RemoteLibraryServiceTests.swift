import Foundation
import GRDB
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsRemote

/// A library asked for over the channel answers as the same library asked
/// directly. The host is the local service with a wire in front of it:
/// these tests are what makes that a checked claim rather than a hope.
@Suite struct RemoteLibraryServiceTests {
    // MARK: - Reads

    @Test(.timeLimit(.minutes(1)))
    func everyBrowseReadAnswersAsTheLocalServiceDoes() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let remote = rig.remote, local = rig.local

        #expect(try await remote.sourceStates() == local.sourceStates())
        #expect(try await remote.sourceStates().map(\.isOnline) == [false, true], "reach is the host's to say")
        #expect(try await remote.browseVocabulary() == local.browseVocabulary())
        for kinds in [MediaKinds.video, .audio, .all] {
            #expect(try await remote.sidebarCounts(kinds: kinds) == local.sidebarCounts(kinds: kinds))
            #expect(try await remote.savedFilterCounts(kinds: kinds) == local.savedFilterCounts(kinds: kinds))
        }
        #expect(try await remote.pendingDuplicateCount() == 1)
        #expect(try await remote.savedFilters() == local.savedFilters())
        #expect(try await remote.tileMenuFacts(snapshotsPerItem: 10) == local.tileMenuFacts(snapshotsPerItem: 10))
        #expect(try await remote.thumbnailQueueStatus() == nil)

        var filtered = MediaFilter()
        filtered.searchText = "a.mp4"
        for request in [
            ListingRequest(
                filter: MediaFilter(), kinds: .video, ordering: .relativePath,
                includesTagData: true, includesDuplicateData: true, snapshotsPerItem: 10),
            ListingRequest(
                filter: filtered, kinds: .video, ordering: .fileSize(ascending: false),
                includesTagData: false, includesDuplicateData: false, snapshotsPerItem: 3),
            ListingRequest(
                filter: MediaFilter(), kinds: .all, ordering: .random(seed: 9),
                includesTagData: true, includesDuplicateData: false, snapshotsPerItem: 0),
        ] {
            #expect(try await remote.listing(request) == local.listing(request))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func everyPlayerReadAnswersAsTheLocalServiceDoes() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let remote = rig.remote, local = rig.local

        #expect(try await remote.itemTags(itemID: rig.a.id) == local.itemTags(itemID: rig.a.id))
        #expect(try await remote.tagging(itemID: rig.a.id) == local.tagging(itemID: rig.a.id))
        #expect(try await remote.segments(parentID: rig.a.id) == local.segments(parentID: rig.a.id))
        #expect(try await remote.segments(parentID: rig.a.id).clips.count == 1)
        #expect(try await remote.searchContext(itemID: rig.a.id) == local.searchContext(itemID: rig.a.id))
        #expect(try await remote.recentlyWatched(limit: 300) == local.recentlyWatched(limit: 300))
        let ids = [rig.b.id, UUID(), rig.a.id]
        #expect(try await remote.items(ids: ids) == local.items(ids: ids))
        for definition: QueueDefinition in [
            .listing(filter: MediaFilter(), kinds: .video, ordering: .relativePath),
            .tag(id: rig.alpha.id, name: "Alpha"), .history, .explicit(ids: ids, name: "Two"),
        ] {
            #expect(try await remote.queueItems(definition) == local.queueItems(definition))
        }
        #expect(try await remote.tagMembership(itemIDs: ids) == local.tagMembership(itemIDs: ids))
        #expect(try await remote.pendingTextScan(itemID: rig.a.id) == nil)
        #expect(try await remote.textLines(itemID: rig.a.id) == local.textLines(itemID: rig.a.id))
        #expect(try await remote.textLines(itemID: rig.a.id).map(\.text) == ["a line of text"])
    }

    /// The host's answer names a file on the host's disk. Here an item is
    /// played from this Mac's own relay to the host, and from nowhere
    /// when the host cannot reach the file.
    @Test(.timeLimit(.minutes(1)))
    func whereAnItemPlaysFromIsThisMacsToSay() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }

        let playable = try await rig.remote.playable(itemID: rig.a.id)
        #expect(try await rig.local.playable(itemID: rig.a.id).item == playable.item)
        let url = try #require(playable.url)
        #expect(url.isFileURL == false, "a path on the host's disk reached the client")
        #expect(url.scheme == "http" && url.host == "127.0.0.1")
        #expect(url.lastPathComponent == "\(rig.a.id.uuidString).mp4")
        #expect(!url.absoluteString.contains(rig.root.path), "the host's folder is in the address")
        // The host cannot reach this one's file: nothing to play from.
        #expect(try await rig.remote.playable(itemID: rig.unmounted.id).url == nil)
        #expect(try await rig.remote.playable(itemID: rig.unmounted.id).item?.id == rig.unmounted.id)
        #expect(try await rig.remote.playable(itemID: UUID()) == Playable(item: nil, url: nil))

        let opened = try await rig.remote.opened(itemID: rig.a.id)
        let direct = try await rig.local.opened(itemID: rig.a.id)
        #expect(opened.playable.url == url, "the same item is played from the same address")
        #expect(opened.tagging == direct.tagging && opened.segments == direct.segments)
        // A segment plays from its video's file: its own id is what is asked for.
        let segment = try #require(try await rig.remote.opened(itemID: rig.segment.id).playable.url)
        #expect(segment.lastPathComponent == "\(rig.segment.id.uuidString).mp4")
        #expect(segment.deletingLastPathComponent() == url.deletingLastPathComponent())

        // Each window's service has a relay of its own, with its own
        // token: an address from one is no use at another.
        let other = RemoteLibraryService(endpoint: rig.endpoint, libraryID: rig.libraryID)
        defer { other.close() }
        let elsewhere = try #require(try await other.playable(itemID: rig.a.id).url)
        #expect(elsewhere != url)
        #expect(other.filesAreOnThisMac == false)
    }

    // MARK: - Writes

    @Test(.timeLimit(.minutes(1)))
    func browseWritesLandInTheHostsLibrary() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let remote = rig.remote

        try await remote.renameSource(rig.source.id, to: "  Shows  ")
        try await remote.setSourceEnabled(rig.away.id, false)
        let sources = try rig.library.sources()
        #expect(sources.first { $0.id == rig.source.id }?.name == "Shows")
        #expect(sources.first { $0.id == rig.away.id }?.enabled == false)

        let saved = try await remote.saveFilter(named: "One", MediaFilter())
        var narrowed = MediaFilter()
        narrowed.searchText = "b"
        try await remote.updateSavedFilter(saved.id, to: narrowed)
        try await remote.renameSavedFilter(saved.id, to: "Two")
        let stored = try #require(try rig.library.savedFilters().first { $0.id == saved.id })
        #expect(stored.name == "Two" && stored.filter == narrowed)
        try await remote.deleteSavedFilter(saved.id)
        #expect(try !rig.library.savedFilters().contains { $0.id == saved.id })

        try await remote.assignTag(rig.beta.id, to: [rig.a.id, rig.b.id])
        #expect(try rig.tagIDs(of: rig.b) == [rig.beta.id])
        try await remote.removeTag(rig.beta.id, from: [rig.a.id])
        #expect(try !rig.tagIDs(of: rig.a).contains(rig.beta.id))
        // The library's rule holds through the wire: one tag of a
        // single-select category.
        try await remote.assignTag(rig.y1996.id, to: [rig.a.id])
        #expect(try rig.tagIDs(of: rig.a) == [rig.alpha.id, rig.y1996.id])

        try await remote.setFavorite([rig.a.id, rig.b.id], true)
        try await remote.setNeedsReview([rig.a.id], false)
        #expect(try rig.row(rig.a)?.isFavorite == true && rig.row(rig.b)?.isFavorite == true)
        #expect(try rig.row(rig.a)?.needsReview == false && rig.row(rig.b)?.needsReview == true)

        // Staging moves the file on the host's disk.
        let gone = UUID()
        let failures = try await remote.setStaging(.toDelete, on: true, itemIDs: [rig.b.id, gone])
        #expect(failures.map(\.itemID) == [gone])
        #expect(try rig.row(rig.b)?.relativePath == "_ToDelete/set/b.mp4")
        #expect(FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("_ToDelete/set/b.mp4").path))
    }

    @Test(.timeLimit(.minutes(1)))
    func playerWritesLandInTheHostsLibrary() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let remote = rig.remote

        let stopped = Date(timeIntervalSince1970: 5_000)
        try await remote.recordPlayback(.started(itemID: rig.b.id, at: Date(timeIntervalSince1970: 4_000)))
        try await remote.recordPlayback(
            .stopped(itemID: rig.b.id, positionSeconds: 120, durationSeconds: 600, at: stopped))
        try await remote.recordPlayback(.completed(itemID: rig.b.id, at: stopped))
        let watched = try #require(try rig.row(rig.b))
        #expect(watched.resumePositionSeconds == 120 && watched.lastWatchedAt == stopped && watched.watchCount == 1)

        let flagged = try await remote.setFlag(.favorite, true, itemID: rig.b.id)
        #expect(flagged.item?.isFavorite == true)
        #expect(try rig.row(rig.b) == flagged.item)

        #expect(try await remote.toggleTag(rig.beta.id, on: rig.b.id) == true)
        #expect(try await remote.toggleTag(rig.beta.id, on: rig.b.id) == false)
        try await remote.renameTag(rig.beta.id, to: "Beta Prime")
        let made = try await remote.ensureTag(named: "Gamma", inCategory: rig.band.id)
        #expect(try await remote.ensureTag(named: "GAMMA", inCategory: rig.band.id).id == made.id)
        try await remote.addAlias("G", toTag: made.id)
        try await remote.setCategoryOrder([rig.year.id, rig.band.id])
        let vocabulary = try rig.library.vocabulary()
        #expect(vocabulary.map(\.category.name).filter { $0 != "Internal" } == ["Year", "Band"])
        #expect(vocabulary.first { $0.category.id == rig.band.id }?.tags.map(\.name)
            == ["Alpha", "Beta Prime", "Gamma"])

        try await remote.setKeyBinding("2", tagID: made.id, advance: true)
        #expect(try rig.library.keyBindings().first { $0.key == "2" }?.advance == true)
        try await remote.removeKeyBinding("2")
        #expect(try !rig.library.keyBindings().contains { $0.key == "2" })

        let clip = try await remote.createSegment(
            parentID: rig.b.id, name: "", startSeconds: 1, endSeconds: 9, role: .clip)
        try await remote.renameSegment(clip.id, to: "Encore")
        #expect(try rig.library.clips(of: rig.b.id).map(\.notes) == ["Encore"])
        try await remote.deleteSegment(clip.id)
        #expect(try rig.library.clips(of: rig.b.id).isEmpty)

        let block = try await remote.addBlock(to: rig.b.id, startSeconds: 2, endSeconds: 4, kind: .hide)
        #expect(try rig.library.blocks(of: rig.b.id).map(\.id) == [block.id])
        try await remote.deleteBlock(block.id)
        #expect(try rig.library.blocks(of: rig.b.id).isEmpty)

        let formats = SearchFormats(formats: [SearchRecipe(name: "Web")])
        try await remote.setSearchFormats(formats, replacingUnreadable: false)
        #expect(try rig.library.searchFormats() == formats)
    }

    /// Jobs are queued on the host's runner, where the files are.
    @Test(.timeLimit(.minutes(1)))
    func aJobAskedForIsQueuedOnTheHost() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }

        let record = try #require(try await rig.remote.run(.remux(itemID: rig.a.id, mode: .optimize), wait: .none))
        let row = try #require(try await rig.library.writer.read { try JobRecord.fetchOne($0, key: record.id) })
        #expect(row.kind == RemuxJob.kind && row.payload == record.payload)
        // A library sweep is queued once, however often asked.
        #expect(try await rig.remote.run(.validation, wait: .none) != nil)
        #expect(try await rig.remote.run(.validation, wait: .none) == nil)
    }

    // MARK: - Failures and refusals

    /// What goes wrong on the host is said in the host's words, and the
    /// connection it was said on goes on working.
    @Test(.timeLimit(.minutes(1)))
    func aFailureOnTheHostArrivesInItsOwnWords() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }

        await #expect(throws: RemoteError.failed("\(ServiceError.emptyName)")) {
            try await rig.remote.renameSource(rig.source.id, to: "   ")
        }
        do {
            try await rig.remote.renameTag(rig.beta.id, to: "alpha")
            Issue.record("a tag was renamed to a name its category already has")
        } catch let error as RemoteError {
            guard case .failed(let words) = error else {
                Issue.record("not the host's failure: \(error)")
                return
            }
            #expect(!words.isEmpty)
        }
        #expect(rig.remote.state == .connected, "a failed request is not a failed connection")
        #expect(try await rig.remote.pendingDuplicateCount() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeviceTheHostHasNotApprovedIsRefused() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        var forged = rig.endpoint
        forged.token = ChannelKey.random(identity: "x").key
        // On a build the host could not talk to, as well: it is told it
        // is not approved, and nothing about the host's build.
        let stranger = RemoteLibraryService(client: RemoteClient(
            endpoint: forged, libraryID: rig.libraryID,
            hello: Hello(
                schema: "a-schema-from-another-build", deviceID: forged.deviceID, token: forged.token,
                libraryID: rig.libraryID)))
        defer { stranger.close() }

        do {
            _ = try await stranger.sourceStates()
            Issue.record("a wrong token was answered")
        } catch let error as RemoteError {
            guard case .refused(let refusal) = error else {
                Issue.record("not a refusal: \(error)")
                return
            }
            #expect(refusal.reason == .notApproved)
        }
        guard case .refused = stranger.state else {
            Issue.record("the state is \(stranger.state)")
            return
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aBuildTheHostCannotTalkToIsToldSo() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        for hello in [
            Hello(protocolVersion: RemoteProtocol.version + 1, deviceID: rig.endpoint.deviceID,
                  token: rig.endpoint.token, libraryID: rig.libraryID),
            Hello(schema: "a-schema-from-another-build", deviceID: rig.endpoint.deviceID,
                  token: rig.endpoint.token, libraryID: rig.libraryID),
        ] {
            let other = RemoteLibraryService(
                client: RemoteClient(endpoint: rig.endpoint, libraryID: rig.libraryID, hello: hello))
            defer { other.close() }
            do {
                _ = try await other.sourceStates()
                Issue.record("a different build was answered")
            } catch let error as RemoteError {
                guard case .refused(let refusal) = error else {
                    Issue.record("not a refusal: \(error)")
                    continue
                }
                #expect(refusal.reason == .versionMismatch)
                #expect(refusal.message.contains("Update"))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aLibraryTheHostDoesNotHaveIsRefusedAndTheOnesItHasAreListed() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }

        let welcome = try await RemoteLibraryService.welcome(from: rig.endpoint)
        #expect(welcome == Welcome(hostName: "The Host", libraries: [RemoteLibraryInfo(id: rig.libraryID, name: "Rig")]))

        let missing = RemoteLibraryService(endpoint: rig.endpoint, libraryID: UUID())
        defer { missing.close() }
        do {
            _ = try await missing.sourceStates()
            Issue.record("a library the host does not have was answered for")
        } catch let error as RemoteError {
            guard case .refused(let refusal) = error else {
                Issue.record("not a refusal: \(error)")
                return
            }
            #expect(refusal.reason == .noSuchLibrary)
        }
    }

    /// Revoked while connected: what it has open is closed, and it is not
    /// let back in.
    @Test(.timeLimit(.minutes(1)))
    func aDeviceRevokedMidSessionIsCutOffAndNotLetBackIn() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        #expect(try await rig.remote.pendingDuplicateCount() == 1)
        #expect(rig.host.sessionCounts.devices == 1)

        rig.door.isOpen = false
        rig.host.closeSessions(of: rig.endpoint.deviceID)

        do {
            _ = try await rig.remote.pendingDuplicateCount()
            Issue.record("a revoked device was answered")
        } catch let error as RemoteError {
            guard case .refused(let refusal) = error else {
                Issue.record("not a refusal: \(error)")
                return
            }
            #expect(refusal.reason == .notApproved)
        }
        #expect(rig.host.sessionCounts.connections == 0)
    }

    /// Revoked, and nothing has closed its connections yet: the one it
    /// has open is still not answered on. Approval is asked at every
    /// request, not only when a connection is made.
    @Test(.timeLimit(.minutes(1)))
    func aDeviceRevokedIsRefusedOnAConnectionItAlreadyHas() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        #expect(try await rig.remote.pendingDuplicateCount() == 1)
        let open = rig.host.sessionCounts.connections
        #expect(open >= 1)

        rig.door.isOpen = false

        do {
            _ = try await rig.remote.pendingDuplicateCount()
            Issue.record("a revoked device was answered on a connection it already had")
        } catch let error as RemoteError {
            guard case .refused(let refusal) = error else {
                Issue.record("not a refusal: \(error)")
                return
            }
            #expect(refusal.reason == .notApproved)
        }
        guard case .refused = rig.remote.state else {
            Issue.record("the state is \(rig.remote.state)")
            return
        }
        // Nor a change to the library: a write is refused the same way.
        await #expect(throws: RemoteError.self) {
            _ = try await rig.remote.toggleTag(rig.beta.id, on: rig.b.id)
        }
        #expect(try rig.tagIDs(of: rig.b).isEmpty)
    }

    /// A revoked device stops being told what the library is doing.
    @Test(.timeLimit(.minutes(1)))
    func aRevokedDevicesChangeStreamIsClosed() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let heard = Heard()
        let ended = Ended()
        let listening = Task {
            for await change in rig.remote.changes() { heard.add(change.domains) }
            ended.set()
        }
        defer { listening.cancel() }
        try await waitUntil("a change is heard") {
            try? rig.library.assignTag(rig.beta.id, to: [rig.b.id])
            try? rig.library.removeTag(rig.beta.id, from: [rig.b.id])
            return !heard.all.isEmpty
        }

        rig.door.isOpen = false
        // The next change is not sent; the stream is closed, the client
        // tries again, is refused, and stops.
        try await waitUntil("the stream ended") {
            try? rig.library.assignTag(rig.beta.id, to: [rig.b.id])
            try? rig.library.removeTag(rig.beta.id, from: [rig.b.id])
            return ended.isSet
        }
        guard case .refused = rig.remote.state else {
            Issue.record("the state is \(rig.remote.state)")
            return
        }
    }

    final class Ended: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    // MARK: - What another Mac may not ask

    /// One request, sent to the host as a paired device's own code never
    /// would: straight down the channel.
    private func askDirectly(_ rig: RemoteRig, _ request: ServiceRequest) async throws -> Frame {
        let connection = FrameConnection(host: "127.0.0.1", port: rig.endpoint.port, key: rig.endpoint.key)
        try await connection.open(timeout: .seconds(5))
        let hello = Hello(deviceID: rig.endpoint.deviceID, token: rig.endpoint.token, libraryID: rig.libraryID)
        try await connection.send(Frame(kind: RemoteProtocol.Kind.hello, payload: try RemoteProtocol.encode(hello)))
        #expect(try await connection.receive().kind == RemoteProtocol.Kind.welcome)
        try await connection.send(
            Frame(kind: RemoteProtocol.Kind.request, payload: try RemoteProtocol.encode(request)))
        let reply = try await connection.receive()
        await connection.close()
        return reply
    }

    /// A source is a folder on the host. Named by another Mac it could be
    /// any folder the host's user can read — the whole disk, as a
    /// "source". It is refused by the host itself, whatever the client's
    /// code would or would not have sent.
    @Test(.timeLimit(.minutes(1)))
    func aSourceCannotBeAddedFromAnotherMac() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let before = try rig.library.sources()

        // The client does not even ask.
        await #expect(throws: RemoteError.self) {
            _ = try await rig.remote.addSource(named: "Everything", rootPath: "/")
        }
        // And a request made by hand is refused where it arrives.
        let reply = try await askDirectly(rig, .addSource(name: "Everything", rootPath: "/"))
        #expect(reply.kind == RemoteProtocol.Kind.failure)
        #expect(String(decoding: reply.payload, as: UTF8.self).contains("added there"))
        #expect(try rig.library.sources() == before)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFolderOutsideASourceCannotBeNamedFromAnotherMac() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        for path in ["../elsewhere", "/etc", "set/../../up", "set//a"] {
            let reply = try await askDirectly(
                rig, .run(request: .joinFolder(sourceID: rig.source.id, folderPath: path), wait: .none))
            #expect(reply.kind == RemoteProtocol.Kind.failure, "\(path) was accepted")
        }
        let queued = try await rig.library.writer.read { try JobRecord.fetchCount($0) }
        #expect(queued == 0)
        // A folder of the source, as the library spells it, is taken.
        let reply = try await askDirectly(
            rig, .run(request: .joinFolder(sourceID: rig.source.id, folderPath: "set"), wait: .none))
        #expect(reply.kind == RemoteProtocol.Kind.answer)
    }

    @Test func onlyWhatReachesOutsideTheLibraryIsHeldBack() {
        #expect(ServiceRequest.addSource(name: "x", rootPath: "/tmp").refusalForAnotherMac != nil)
        #expect(ServiceRequest.sourceStates.refusalForAnotherMac == nil)
        #expect(ServiceRequest.renameSource(id: UUID(), name: "x").refusalForAnotherMac == nil)
        #expect(ServiceRequest.setStaging(folder: .toDelete, on: true, itemIDs: []).refusalForAnotherMac == nil)
        #expect(ServiceRequest.run(request: .validation, wait: .none).refusalForAnotherMac == nil)
    }

    // MARK: - The connection

    @Test(.timeLimit(.minutes(1)))
    func manyRequestsAtOnceAreAllAnswered() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let expected = try await rig.local.sourceStates()

        let answers = try await withThrowingTaskGroup(of: [SourceState].self) { group in
            for _ in 0..<40 { group.addTask { try await rig.remote.sourceStates() } }
            var all: [[SourceState]] = []
            for try await answer in group { all.append(answer) }
            return all
        }
        #expect(answers.count == 40)
        #expect(answers.allSatisfy { $0 == expected })
        #expect(rig.host.sessionCounts.connections <= RemoteClient.limit, "more connections than the pool allows")
    }

    /// The host closes every connection when a device is paired or
    /// revoked. A read that finds its connection gone is asked again on a
    /// new one; nothing is shown as broken.
    @Test(.timeLimit(.minutes(1)))
    func aReadWhoseConnectionTheHostClosedIsAskedAgain() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        #expect(try await rig.remote.pendingDuplicateCount() == 1)

        try await rig.listener.replaceKeys([rig.endpoint.key])

        #expect(try await rig.remote.pendingDuplicateCount() == 1)
        #expect(rig.remote.state == .connected)
    }

    /// A request that changes the library is never asked twice, so it
    /// must not be sent down a connection that has died. The host closed
    /// this one a moment ago; the toggle still lands, and lands once.
    @Test(.timeLimit(.minutes(1)))
    func aWriteAfterTheHostClosedItsConnectionsLandsOnce() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        #expect(try await rig.remote.pendingDuplicateCount() == 1)

        try await rig.listener.replaceKeys([rig.endpoint.key])

        #expect(try await rig.remote.toggleTag(rig.beta.id, on: rig.b.id) == true)
        #expect(try rig.tagIDs(of: rig.b) == [rig.beta.id], "the toggle was carried out other than once")
    }

    /// A connection that has completed the channel's handshake has shown
    /// it holds a key, not who it is or that it is still welcome. Until
    /// it has said hello and been welcomed, a request gets no answer.
    @Test(.timeLimit(.minutes(1)))
    func nothingIsAnsweredBeforeTheHello() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let connection = FrameConnection(host: "127.0.0.1", port: rig.endpoint.port, key: rig.endpoint.key)
        try await connection.open(timeout: .seconds(5))
        try await connection.send(Frame(
            kind: RemoteProtocol.Kind.request, payload: try RemoteProtocol.encode(ServiceRequest.sourceStates)))
        await #expect(throws: ChannelError.self) { _ = try await connection.receive() }
        await connection.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aHostThatHasGoneIsAnErrorAndSaysSoInTheState() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        #expect(try await rig.remote.pendingDuplicateCount() == 1)
        #expect(rig.remote.state == .connected)

        rig.host.stop()
        try await Task.sleep(for: .milliseconds(200))

        do {
            _ = try await rig.remote.pendingDuplicateCount()
            Issue.record("a host that has stopped was heard from")
        } catch let error as RemoteError {
            guard case .unreachable = error else {
                Issue.record("not unreachable: \(error)")
                return
            }
        }
        guard case .reconnecting = rig.remote.state else {
            Issue.record("the state is \(rig.remote.state)")
            return
        }
    }

    // MARK: - Changes

    @Test(.timeLimit(.minutes(1)))
    func aChangeOnTheHostReachesTheClient() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let heard = Heard()
        let listening = Task {
            for await change in rig.remote.changes() { heard.add(change.domains) }
        }
        defer { listening.cancel() }
        try await waitUntil("the stream is connected") { rig.remote.state == .connected }
        // The host's subscription is made a moment after the client's
        // frame arrives; a change is tried until one is heard.
        try await waitUntil("a tagging change") {
            try? rig.library.assignTag(rig.beta.id, to: [rig.b.id])
            try? rig.library.removeTag(rig.beta.id, from: [rig.b.id])
            return heard.all.contains { $0.contains(.tagging) }
        }

        try await rig.library.writer.write { db in
            try MediaItem(sourceID: rig.source.id, kind: .video, relativePath: "new.mp4", needsReview: false).insert(db)
        }
        try await waitUntil("an items change") { heard.all.contains { $0.contains(.items) } }
    }

    /// The stream's connection is lost — the host closed it — and made
    /// again. Whatever changed meanwhile was not heard, so the first word
    /// afterwards is that everything may have.
    @Test(.timeLimit(.minutes(1)))
    func afterTheStreamReconnectsEverythingIsSaidToHaveChanged() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let heard = Heard()
        let listening = Task {
            for await change in rig.remote.changes() { heard.add(change.domains) }
        }
        defer { listening.cancel() }
        try await waitUntil("the stream is connected") { rig.host.sessionCounts.connections >= 1 }

        try await rig.listener.replaceKeys([rig.endpoint.key])

        try await waitUntil("everything, after the reconnect") {
            heard.all.contains(Set(LibraryChangeDomain.allCases))
        }
        // And it is following again.
        let before = heard.all.count
        try await waitUntil("a change after the reconnect") {
            try? rig.library.assignTag(rig.beta.id, to: [rig.b.id])
            try? rig.library.removeTag(rig.beta.id, from: [rig.b.id])
            return heard.all.count > before
        }
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [Set<LibraryChangeDomain>] = []
        func add(_ domains: Set<LibraryChangeDomain>) { lock.withLock { changes.append(domains) } }
        var all: [Set<LibraryChangeDomain>] { lock.withLock { changes } }
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), "\(what): never happened")
    }

    // MARK: - Size

    /// An answer large enough to be compressed arrives whole.
    @Test(.timeLimit(.minutes(1)))
    func aLargeListingArrivesWhole() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        try await rig.library.writer.write { db in
            for index in 0..<3_000 {
                try MediaItem(
                    sourceID: rig.source.id, kind: .video,
                    relativePath: "bulk/show-\(index)/disc-\(index % 7).mp4", needsReview: index % 3 == 0
                ).insert(db)
            }
        }
        let request = ListingRequest(
            filter: MediaFilter(), kinds: .video, ordering: .relativePath,
            includesTagData: true, includesDuplicateData: true, snapshotsPerItem: 10)
        let direct = try await rig.local.listing(request)
        #expect(direct.items.count > 3_000)
        #expect(try await rig.remote.listing(request) == direct)
        // It was compressed on its way: the frame is a fraction of the JSON.
        let json = try RemoteProtocol.encode(direct)
        let frame = RemoteProtocol.answerFrame(json)
        #expect(frame.kind == RemoteProtocol.Kind.compressedAnswer)
        #expect(frame.payload.count * 3 < json.count)
        #expect(try RemoteProtocol.answerJSON(frame) == json)
    }

    /// The question the design carried forward: is a listing of a very
    /// large library, every item in one answer, usable over the wire?
    /// This measures it. It is left out of the merge gate.
    @Test(.measuresALargeLibrary, .timeLimit(.minutes(3)))
    func aListingOfFiftyThousandItemsIsMeasured() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        try await rig.library.writer.write { db in
            for index in 0..<50_000 {
                try MediaItem(
                    sourceID: rig.source.id, kind: .video,
                    relativePath: "bulk/\(index % 400)/show-\(index)-a-reasonably-long-file-name.mp4",
                    fileSize: Int64(700_000_000 + index), durationSeconds: 3_600 + Double(index % 900),
                    width: 1920, height: 1080, videoCodec: "h264", audioCodec: "aac", needsReview: index % 3 == 0
                ).insert(db)
            }
        }
        let request = ListingRequest(
            filter: MediaFilter(), kinds: .video, ordering: .relativePath,
            includesTagData: false, includesDuplicateData: false, snapshotsPerItem: 10)
        let clock = ContinuousClock()

        var direct: BrowseListingAnswer?
        let localTime = try await clock.measure { direct = try await rig.local.listing(request) }
        var overTheWire: BrowseListingAnswer?
        let remoteTime = try await clock.measure { overTheWire = try await rig.remote.listing(request) }
        let json = try RemoteProtocol.encode(try #require(direct))
        let frame = RemoteProtocol.answerFrame(json)

        print("""
            MEASURED a listing of \(direct?.items.count ?? 0) items: \
            local \(localTime), over loopback \(remoteTime); \
            JSON \(json.count / 1_048_576) MB, on the wire \(frame.payload.count / 1_048_576) MB \
            (\(frame.payload.count * 100 / max(json.count, 1))%)
            """)
        #expect(overTheWire == direct)
        #expect(json.count <= FrameCodec.maximumPayload, "the answer is larger than a frame may be")
    }
}
