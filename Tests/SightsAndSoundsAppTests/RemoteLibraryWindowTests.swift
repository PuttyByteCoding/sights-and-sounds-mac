import Foundation
import GRDB
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp
@testable import SightsAndSoundsRemote

/// This Mac as the one that connects: pairing with another, listing its
/// libraries, and a Browse window over one of them. The "other Mac" is a
/// host in this process, on loopback, with a small library of its own.
@Suite @MainActor struct RemoteLibraryWindowTests {
    /// The Mac that holds the library.
    final class OtherMac: @unchecked Sendable {
        let folder: URL
        let library: LibraryDatabase
        let libraryID: UUID
        let service: LocalLibraryService
        let host: RemoteHost
        let a: MediaItem
        let b: MediaItem
        /// On a source that is not mounted: listed, tagged, not played.
        let away: MediaItem
        let tag: SightsAndSoundsKit.Tag

        init(named name: String = "The Den Mac") async throws {
            folder = AppSettingsStore.testScratch
                .appendingPathComponent("other-mac-\(UUID().uuidString)", isDirectory: true)
            let media = folder.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try Data("a".utf8).write(to: media.appendingPathComponent("a.mp4"))
            try Data("b".utf8).write(to: media.appendingPathComponent("b.mp4"))

            let library = try LibraryDatabase.openInMemory()
            let info = try library.ensureInfo(name: "Concerts")
            let source = Source(name: "Shows", rootPath: media.path)
            let category = TagCategory(name: "Band", sortOrder: 0)
            let tag = SightsAndSoundsKit.Tag(tagCategoryID: category.id, name: "Alpha")
            let a = MediaItem(sourceID: source.id, kind: .video, relativePath: "a.mp4", durationSeconds: 60)
            let b = MediaItem(sourceID: source.id, kind: .video, relativePath: "b.mp4", durationSeconds: 60)
            let elsewhere = Source(name: "Unplugged", rootPath: media.path + "-not-mounted")
            let away = MediaItem(sourceID: elsewhere.id, kind: .audio, relativePath: "c.m4a", durationSeconds: 60)
            try await library.writer.write { db in
                try source.insert(db)
                try elsewhere.insert(db)
                try category.insert(db)
                try tag.insert(db)
                try a.insert(db)
                try b.insert(db)
                try away.insert(db)
            }
            try library.assignTag(tag.id, to: [a.id])
            self.away = away
            self.library = library
            self.libraryID = info.libraryID
            self.a = a
            self.b = b
            self.tag = tag
            let service = LocalLibraryService(
                library: library, runner: JobRunner(library: library, paused: true))
            self.service = service
            let libraryID = info.libraryID
            host = RemoteHost(
                store: try DeviceStore(file: folder.appendingPathComponent("approved-devices.json")),
                hostName: { name },
                libraries: { [RemoteLibraryInfo(id: libraryID, name: "Concerts")] },
                service: { $0 == libraryID ? service : nil },
                approve: { _ in true })
            try await host.start()
        }

        func code() async throws -> String {
            try await host.beginPairing(address: "127.0.0.1").text
        }

        func tearDown() async {
            await host.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func hostsFile() -> URL {
        AppSettingsStore.testScratch
            .appendingPathComponent("this-mac-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("hosts.json")
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(25)) }
        #expect(condition(), "\(what): never happened")
    }

    private func window(_ ref: RemoteLibraryRef, _ remote: RemoteLibrariesModel) throws -> BrowseModel {
        let service = try #require(remote.service(for: ref.id))
        return try BrowseModel(
            libraryID: ref.id, name: ref.library.name, hostName: ref.host.name, service: service,
            connection: RemoteConnectionNote.notes(of: service, hostName: ref.host.name))
    }

    // MARK: - Pairing, and what is listed

    @Test(.timeLimit(.minutes(1)))
    func aPairedMacsLibrariesAreListedAndRemembered() async throws {
        let other = try await OtherMac()
        let file = hostsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let remote = RemoteLibrariesModel(file: file)
        #expect(remote.isAvailable && remote.hosts.isEmpty)

        let saved = try await remote.pair(codeText: "  \(try await other.code())\n", as: "Studio MacBook")
        #expect(other.host.devices.map(\.name) == ["Studio MacBook"])
        let entry = try #require(remote.hosts.first)
        #expect(remote.hosts.count == 1)
        #expect(entry.host.id == saved.id && entry.host.name == "The Den Mac")
        #expect(entry.state == .reachable)
        #expect(entry.libraries.map(\.library) == [RemoteLibraryInfo(id: other.libraryID, name: "Concerts")])

        // Next launch: what it had is listed at once, before it is asked.
        let later = RemoteLibrariesModel(file: file)
        #expect(later.hosts.first?.state == .asking)
        #expect(later.hosts.first?.libraries.map(\.library.name) == ["Concerts"])
        #expect(later.ref(for: entry.libraries[0].id)?.library == entry.libraries[0].library)
        #expect(later.ref(for: entry.libraries[0].id)?.host.id == saved.id)

        // And still listed when that Mac is off: said to be not answering.
        await other.tearDown()
        await later.refresh()
        guard case .unreachable = later.hosts.first?.state else {
            Issue.record("the state is \(String(describing: later.hosts.first?.state))")
            return
        }
        #expect(later.hosts.first?.libraries.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func whatIsNotACodeIsSaidToBeNone() async throws {
        let file = hostsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let remote = RemoteLibrariesModel(file: file)
        await #expect(throws: RemoteLibrariesModel.NotACode.self) {
            try await remote.pair(codeText: "hello", as: "Studio MacBook")
        }
        #expect(remote.hosts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path), "a file was written for nothing")
    }

    /// A Mac revoked on the other side is told so, in that Mac's words.
    @Test(.timeLimit(.minutes(1)))
    func aMacThatWasRevokedIsToldSo() async throws {
        let other = try await OtherMac()
        let file = hostsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let remote = RemoteLibrariesModel(file: file)
        let saved = try await remote.pair(codeText: try await other.code(), as: "Studio MacBook")

        try await other.host.revoke(saved.id)
        await remote.refresh()
        // Its key is no longer a key there: no connection at all.
        #expect(RemoteHostHeaderState.isTrouble(remote.hosts.first?.state))
        #expect(remote.hosts.first?.libraries.count == 1, "what it had is still listed")

        remote.forget(saved.id)
        #expect(remote.hosts.isEmpty)
        #expect(RemoteLibrariesModel(file: file).hosts.isEmpty)
        await other.tearDown()
    }

    @Test(.timeLimit(.minutes(1)))
    func aMacThatMovedIsFoundAtItsNewAddress() async throws {
        let other = try await OtherMac()
        let file = hostsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let remote = RemoteLibrariesModel(file: file)
        let saved = try await remote.pair(codeText: try await other.code(), as: "Studio MacBook")

        await remote.move(saved.id, toAddress: "127.0.0.1", port: saved.port == 9 ? 10 : 9)
        guard case .unreachable = remote.hosts.first?.state else {
            Issue.record("the state is \(String(describing: remote.hosts.first?.state))")
            return
        }
        await remote.move(saved.id, toAddress: "127.0.0.1", port: saved.port)
        #expect(remote.hosts.first?.state == .reachable)
        #expect(remote.hosts.first?.host.id == saved.id, "the pairing was not kept")
        await other.tearDown()
    }

    // MARK: - The id a remote library goes by here

    @Test func aRemoteLibraryHasAnIdOfItsOwnHere() {
        let host = UUID(), otherHost = UUID(), library = UUID()
        let id = RemoteLibraryRef.windowID(hostID: host, libraryID: library)
        #expect(id == RemoteLibraryRef.windowID(hostID: host, libraryID: library), "not the same twice")
        #expect(id != library, "it would be taken for a library on this Mac with that id")
        #expect(id != RemoteLibraryRef.windowID(hostID: otherHost, libraryID: library))
        #expect(id != RemoteLibraryRef.windowID(hostID: host, libraryID: UUID()))
        #expect(id != RemoteLibraryRef.windowID(hostID: library, libraryID: host), "the two halves are told apart")
    }

    // MARK: - The window

    @Test(.timeLimit(.minutes(1)))
    func aWindowOnAnotherMacsLibraryShowsItAndChangesIt() async throws {
        let other = try await OtherMac()
        let file = hostsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let remote = RemoteLibrariesModel(file: file)
        try await remote.pair(codeText: try await other.code(), as: "Studio MacBook")
        let ref = try #require(remote.hosts.first?.libraries.first)
        defer { remote.closeService(for: ref.id) }

        let model = try window(ref, remote)
        #expect(model.isRemote)
        #expect(model.libraryName == "Concerts" && model.remoteHostName == "The Den Mac")
        await eventually("the listing arrives") { model.visibleItems.count == 2 }
        #expect(model.sources.map(\.name) == ["Shows", "Unplugged"])
        #expect(model.vocabulary.flatMap(\.tags).map(\.name) == ["Alpha"])
        await eventually("connected") { model.connectionNote == nil }

        // Its files are on the other Mac: nothing here goes to the Finder.
        let a = try #require(model.visibleItems.first { $0.id == other.a.id })
        #expect(model.fileURL(for: a) == nil)
        #expect(model.dragFileURL(for: a) == nil)
        #expect(model.storedThumbnail(for: a) != nil, "the other Mac is not asked for its thumbnails")
        // Where it plays from is this Mac's own relay to the other.
        let playsFrom = try #require(await model.fileResolver(for: a)())
        #expect(playsFrom.scheme == "http" && playsFrom.host == "127.0.0.1")
        #expect(playsFrom.lastPathComponent == "\(other.a.id.uuidString).mp4")

        // A change made here is made there, and comes back in the listing.
        await model.setFavorite(a, true)
        #expect(try await other.library.writer.read { try MediaItem.fetchOne($0, key: other.a.id) }?.isFavorite == true)
        await eventually("the tile shows it") { model.visibleItems.first { $0.id == other.a.id }?.isFavorite == true }
        await model.removeTag(other.tag.id, from: a)
        let left = try await other.library.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mediaItemTag WHERE mediaItemID = ?", arguments: [other.a.id])
        }
        #expect(left == 0)

        // A change made there shows up here without being asked for.
        try other.library.assignTag(other.tag.id, to: [other.b.id])
        model.filter = MediaFilter(required: [.tag(other.tag.id)])
        await eventually("the other Mac's change is listed") { model.visibleItems.map(\.id) == [other.b.id] }
        #expect(model.errorMessage == nil)
        await other.tearDown()
    }

    /// What stands behind the surfaces not yet moved, if one is reached:
    /// a library with nothing in it that takes no change. Never some
    /// other library.
    @Test(.timeLimit(.minutes(1)))
    func theWindowHasNoDatabaseToGiveAway() async throws {
        let other = try await OtherMac()
        let file = hostsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let remote = RemoteLibrariesModel(file: file)
        try await remote.pair(codeText: try await other.code(), as: "Studio MacBook")
        let ref = try #require(remote.hosts.first?.libraries.first)
        defer { remote.closeService(for: ref.id) }
        let model = try window(ref, remote)

        #expect(try model.library.sources().isEmpty)
        #expect(try model.library.info() == nil)
        #expect(throws: (any Error).self) { try model.library.ensureInfo(name: "Written Here") }
        #expect(throws: (any Error).self) { try model.library.assignTag(other.tag.id, to: [other.a.id]) }
        #expect(try model.library.info() == nil, "a change got in")

        // And the app, asked for a library by this window's id, has none.
        let app = AppModel()
        #expect(throws: (any Error).self) { try app.library(for: ref.id) }
        #expect(model.libraryID == ref.id && model.libraryID != other.libraryID)
        await other.tearDown()
    }

    @Test(.timeLimit(.minutes(1)))
    func theWindowSaysWhenTheOtherMacStopsAnswering() async throws {
        let other = try await OtherMac()
        let file = hostsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let remote = RemoteLibrariesModel(file: file)
        try await remote.pair(codeText: try await other.code(), as: "Studio MacBook")
        let ref = try #require(remote.hosts.first?.libraries.first)
        defer { remote.closeService(for: ref.id) }
        let model = try window(ref, remote)
        await eventually("the listing arrives") { model.visibleItems.count == 2 }
        await eventually("connected") { model.connectionNote == nil }

        await other.host.stop()
        model.refreshItems()
        await eventually("it says the other Mac is not answering") {
            model.connectionNote?.contains("The Den Mac is not answering") == true
        }
        // What was on screen stays there.
        #expect(model.visibleItems.count == 2)

        // Back on, at the same address: the window recovers by itself.
        try await other.host.start()
        await eventually("connected again") {
            if model.connectionNote != nil { model.refreshItems() }
            return model.connectionNote == nil
        }
        await other.tearDown()
    }

    /// The player in that window: the same player, asked of the other
    /// Mac. An item whose drive is unplugged there is still opened and
    /// tagged, as it would be there.
    @Test(.timeLimit(.minutes(1)))
    func thePlayerInThatWindowTagsOnTheOtherMac() async throws {
        let other = try await OtherMac()
        let file = hostsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let remote = RemoteLibrariesModel(file: file)
        try await remote.pair(codeText: try await other.code(), as: "Studio MacBook")
        let ref = try #require(remote.hosts.first?.libraries.first)
        defer { remote.closeService(for: ref.id) }
        let browse = try window(ref, remote)

        let player = PlayerModel(
            request: PlayerRequest(
                libraryID: ref.id, itemID: other.away.id, playlist: [other.away.id], name: "One"),
            library: browse.library, appDatabase: nil, service: browse.service)
        await eventually("the item is opened") { player.item?.id == other.away.id && player.isSettled }
        #expect(player.itemTags.flatMap(\.tags).isEmpty)

        player.toggleTag(other.tag.id)
        await eventually("the tag is on it") { player.itemTags.flatMap(\.tags).map(\.id) == [other.tag.id] }
        let onTheOtherMac = try await other.library.writer.read { db in
            try UUID.fetchAll(db, sql: "SELECT tagID FROM mediaItemTag WHERE mediaItemID = ?", arguments: [other.away.id])
        }
        #expect(onTheOtherMac == [other.tag.id])
        await other.tearDown()
    }

    @Test func howTheConnectionStandsIsSaidInWords() {
        #expect(RemoteConnectionNote.text(for: .connected, hostName: "Den") == nil)
        #expect(RemoteConnectionNote.text(for: .connecting, hostName: "Den") == "Connecting to Den\u{2026}")
        #expect(RemoteConnectionNote.text(for: .reconnecting("x"), hostName: "Den")?.hasPrefix("Den is not answering") == true)
        #expect(RemoteConnectionNote.text(for: .refused("Revoked there."), hostName: "Den")
            == "Den will not have this Mac: Revoked there.")
    }

    // MARK: - The app

    /// Closing the window lets go of the other Mac; forgetting the Mac
    /// does too.
    @Test(.timeLimit(.minutes(1)))
    func closingTheWindowOrForgettingTheMacLetsGoOfIt() async throws {
        let other = try await OtherMac()
        let app = AppModel()
        let remote = app.remoteLibraries
        let saved = try await remote.pair(codeText: try await other.code(), as: "Studio MacBook")
        defer { remote.forget(saved.id) }
        let ref = try #require(remote.ref(for: RemoteLibraryRef.windowID(hostID: saved.id, libraryID: other.libraryID)))

        let first = try #require(remote.service(for: ref.id))
        #expect(remote.service(for: ref.id) === first, "a second service for the same window")
        #expect(try await first.sourceStates().count == 2)
        app.libraryWindowAppeared(ref.id)
        #expect(app.openLibraryIDs.contains(ref.id))

        // A player opened beside it — a tag's "Show Items with This
        // Tag" — shares the connection, and keeps it when the library's
        // own window closes first.
        remote.windowOpened(ref.id)
        app.libraryWindowDisappeared(ref.id)
        #expect(try await first.sourceStates().count == 2, "the player's connection went with the other window")
        #expect(remote.service(for: ref.id) === first)
        remote.windowClosed(ref.id)
        await #expect(throws: (any Error).self) { _ = try await first.sourceStates() }
        let second = try #require(remote.service(for: ref.id))
        #expect(second !== first)
        #expect(try await second.sourceStates().count == 2)

        // A window with no library window's model to ask — Library
        // Properties — is given the same connection by the app.
        #expect(try app.service(for: ref.id) as AnyObject === second)
        #expect(try await app.service(for: ref.id).libraryProperties().info?.name == "Concerts")
        // And for an id that is nobody's, there is no service to give.
        #expect(throws: (any Error).self) { _ = try app.service(for: UUID()) }

        remote.forget(saved.id)
        await #expect(throws: (any Error).self) { _ = try await second.sourceStates() }
        #expect(remote.ref(for: ref.id) == nil)
        #expect(remote.service(for: ref.id) == nil)
        await other.tearDown()
    }

    /// Background Tasks shows a lane for a library on another Mac while
    /// a window is open on it, and the queue it shows and steers is that
    /// Mac's.
    @Test(.timeLimit(.minutes(1)))
    func anOpenRemoteLibraryHasALaneAndTheQueueIsTheOtherMacs() async throws {
        let other = try await OtherMac()
        let app = AppModel()
        let remote = app.remoteLibraries
        let saved = try await remote.pair(codeText: try await other.code(), as: "Studio MacBook")
        defer { remote.forget(saved.id) }
        let ref = try #require(remote.ref(for: RemoteLibraryRef.windowID(hostID: saved.id, libraryID: other.libraryID)))

        // Paired and not open: no lane, and nothing is connected to ask.
        #expect(await BackgroundTasksView.lanes(of: app).isEmpty)
        #expect(app.openLibraries(withAWindow: true).isEmpty)

        _ = try #require(remote.service(for: ref.id))
        app.libraryWindowAppeared(ref.id)
        // The other Mac's queue is paused, and has one sweep waiting.
        try await other.service.startSweep(.contentHash, after: .nothing)

        let lane = try #require(await BackgroundTasksView.lanes(of: app).first { $0.id == ref.id })
        #expect(lane.name == "Concerts — The Den Mac")
        #expect(lane.isAnswering && lane.isPaused)
        #expect(lane.queued == 1)
        #expect(app.openLibraries(withAWindow: true).map(\.id) == [ref.id])

        // Cancelled from here, it is cancelled there.
        let job = try #require(lane.jobs.first)
        try await app.service(for: ref.id).cancelJob(id: job.id)
        #expect(try await other.service.job(id: job.id)?.state == .cancelled)
        // And the sweeps panel's counts are the other Mac's.
        let statuses = try await app.service(for: ref.id).sweepStatuses()
        #expect(statuses == (try await other.service.sweepStatuses()))

        // The other Mac going away is said on its lane, not left as it was.
        await other.host.stop()
        let after = try #require(await BackgroundTasksView.lanes(of: app).first { $0.id == ref.id })
        #expect(!after.isAnswering && after.jobs.isEmpty)

        app.libraryWindowDisappeared(ref.id)
        #expect(await BackgroundTasksView.lanes(of: app).isEmpty)
        await other.tearDown()
    }
}

/// The picker's reading of a host's state, where a test can reach it.
enum RemoteHostHeaderState {
    static func isTrouble(_ state: RemoteLibrariesModel.HostEntry.State?) -> Bool {
        switch state {
        case .unreachable, .refused: true
        default: false
        }
    }
}
