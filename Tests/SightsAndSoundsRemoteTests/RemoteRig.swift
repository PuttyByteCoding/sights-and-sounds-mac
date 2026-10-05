import Foundation
import GRDB
import SightsAndSoundsKit

@testable import SightsAndSoundsRemote

/// Both ends on one Mac: a library with one of everything, the service
/// for it as the host's own windows would have it, a host serving that
/// over loopback, and a client's service connected to the host.
final class RemoteRig: @unchecked Sendable {
    /// Whether the host approves the rig's device, switchable mid-test.
    final class Door: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        var isOpen: Bool {
            get { lock.withLock { open } }
            set { lock.withLock { open = newValue } }
        }
    }

    let root: URL
    let library: LibraryDatabase
    let runner: JobRunner
    let local: LocalLibraryService
    let listener: FrameListener
    let host: ServiceHost
    let endpoint: RemoteEndpoint
    let libraryID = UUID()
    let door = Door()
    let remote: RemoteLibraryService

    let source: Source
    let away: Source
    let band: TagCategory
    let year: TagCategory
    let alpha: SightsAndSoundsKit.Tag
    let beta: SightsAndSoundsKit.Tag
    let y1995: SightsAndSoundsKit.Tag
    let y1996: SightsAndSoundsKit.Tag
    let a: MediaItem
    let b: MediaItem
    let unmounted: MediaItem
    let segment: MediaItem

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-remote-rig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("set"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("set/a.mp4"))
        try Data("b".utf8).write(to: root.appendingPathComponent("set/b.mp4"))

        let library = try LibraryDatabase.openInMemory()
        try library.ensureInfo(name: "Rig")
        let source = Source(name: "Here", rootPath: root.path)
        let away = Source(name: "Away", rootPath: root.path + "-not-mounted")
        let band = TagCategory(name: "Band", sortOrder: 0)
        let year = TagCategory(name: "Year", allowMultiple: false, sortOrder: 1)
        let hidden = TagCategory(name: "Internal", sortOrder: 2, hiddenFromBrowse: true)
        let alpha = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Alpha")
        let beta = SightsAndSoundsKit.Tag(tagCategoryID: band.id, name: "Beta")
        let y1995 = SightsAndSoundsKit.Tag(tagCategoryID: year.id, name: "1995")
        let y1996 = SightsAndSoundsKit.Tag(tagCategoryID: year.id, name: "1996")
        let a = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "set/a.mp4", durationSeconds: 600, needsReview: true)
        let b = MediaItem(
            sourceID: source.id, kind: .video, relativePath: "set/b.mp4", durationSeconds: 600, needsReview: true)
        let unmounted = MediaItem(sourceID: away.id, kind: .video, relativePath: "c.mp4", needsReview: false)
        try await library.writer.write { db in
            for row in [source, away] { try row.insert(db) }
            for row in [band, year, hidden] { try row.insert(db) }
            for row in [alpha, beta, y1995, y1996] { try row.insert(db) }
            try SightsAndSoundsKit.Tag(tagCategoryID: hidden.id, name: "Secret").insert(db)
            for row in [a, b, unmounted] { try row.insert(db) }
            try DuplicateCandidate(itemA: a.id, itemB: b.id, source: .contentHash).insert(db)
            try db.execute(
                sql: "INSERT INTO ocrTextLine (id, mediaItemID, timeSeconds, text) VALUES (?, ?, ?, ?)",
                arguments: [UUID(), a.id, 3.0, "a line of text"])
        }
        try library.assignTag(alpha.id, to: [a.id])
        try library.assignTag(y1995.id, to: [a.id])
        try library.addAlias("A", toTag: alpha.id)
        try library.setKeyBinding("1", tagID: alpha.id)
        segment = try library.createEmbeddedClip(
            parentID: a.id, name: "Song", startSeconds: 10, endSeconds: 20, role: .song)
        _ = try library.addBlock(to: a.id, startSeconds: 30, endSeconds: 40)
        var shows = MediaFilter()
        shows.selectSubtree("set", sourceID: source.id)
        _ = try library.saveFilter(named: "Shows", shows)
        try library.recordPlaybackStart(itemID: a.id, at: Date(timeIntervalSince1970: 100))

        self.library = library
        self.source = source
        self.away = away
        self.band = band
        self.year = year
        self.alpha = alpha
        self.beta = beta
        self.y1995 = y1995
        self.y1996 = y1996
        self.a = a
        self.b = b
        self.unmounted = unmounted

        // A paused runner: jobs are queued and seen, and none runs.
        runner = JobRunner(library: library, paused: true)
        local = LocalLibraryService(library: library, runner: runner)

        let key = ChannelKey.random(identity: "rig-device")
        let deviceID = UUID()
        let token = ChannelKey.random(identity: "token").key
        let listener = FrameListener(keys: [key])
        let libraryID = libraryID, local = local, door = door
        host = ServiceHost(listener: listener, directory: HostDirectory(
            hostName: { "The Host" },
            approves: { device, given in door.isOpen && device == deviceID && given == token },
            libraries: { [RemoteLibraryInfo(id: libraryID, name: "Rig")] },
            service: { $0 == libraryID ? local : nil }))
        let port = try await host.start()
        self.listener = listener
        endpoint = RemoteEndpoint(host: "127.0.0.1", port: port, key: key, deviceID: deviceID, token: token)
        remote = RemoteLibraryService(endpoint: endpoint, libraryID: libraryID)
    }

    func tearDown() {
        remote.close()
        host.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func row(_ item: MediaItem) throws -> MediaItem? {
        try library.writer.read { try MediaItem.fetchOne($0, key: item.id) }
    }

    func tagIDs(of item: MediaItem) throws -> Set<UUID> {
        Set(try library.writer.read { db in
            try UUID.fetchAll(db, sql: "SELECT tagID FROM mediaItemTag WHERE mediaItemID = ?", arguments: [item.id])
        })
    }
}
