import AVFoundation
import Foundation
import Network
import Testing

import SightsAndSoundsKit
@testable import SightsAndSoundsRemote

/// An item's file, reaching this Mac from the host: asked for through
/// the channel by the item's id, and played from a relay on this Mac's
/// own loopback.
@Suite struct MediaTests {
    /// Bytes that are different everywhere, so a piece from the wrong
    /// place cannot pass for the right one.
    private func pattern(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var state: UInt32 = 0x9E37_79B9
            for index in 0..<count {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        return data
    }

    /// The rig, with `set/a.mp4` holding `size` bytes of pattern.
    private func rig(fileOf size: Int) async throws -> (RemoteRig, Data) {
        let rig = try await RemoteRig()
        let contents = pattern(size)
        try contents.write(to: rig.root.appendingPathComponent("set/a.mp4"))
        return (rig, contents)
    }

    private func fetch(
        _ url: URL, range: String? = nil, method: String = "GET"
    ) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (try #require(response as? HTTPURLResponse), data)
    }

    // MARK: - Through the channel

    @Test(.timeLimit(.minutes(1)))
    func aPieceOfAFileComesBackAsItIs() async throws {
        let (rig, contents) = try await rig(fileOf: 2_500_000)
        defer { rig.tearDown() }
        let total = Int64(contents.count)

        let start = try await rig.remote.fileBytes(itemID: rig.a.id, offset: 0, length: 100)
        #expect(start == MediaBytes(total: total, data: contents.prefix(100)))
        let middle = try await rig.remote.fileBytes(itemID: rig.a.id, offset: 1_234_567, length: 4_321)
        #expect(middle.data == contents[1_234_567..<(1_234_567 + 4_321)])
        // Back again in the same file, as a seek is.
        let earlier = try await rig.remote.fileBytes(itemID: rig.a.id, offset: 10, length: 10)
        #expect(earlier.data == contents[10..<20])

        // The end of the file is where the bytes stop, not an error.
        let tail = try await rig.remote.fileBytes(itemID: rig.a.id, offset: total - 5, length: 100)
        #expect(tail.data == contents.suffix(5))
        let past = try await rig.remote.fileBytes(itemID: rig.a.id, offset: total + 10, length: 100)
        #expect(past == MediaBytes(total: total, data: Data()))
        // Nothing asked for: how long the file is, and nothing else.
        #expect(try await rig.remote.fileBytes(itemID: rig.a.id, offset: 0, length: 0)
            == MediaBytes(total: total, data: Data()))
    }

    /// However much is asked for, an answer is at most a megabyte: the
    /// host does not read a whole video into memory because it was told
    /// to.
    @Test(.timeLimit(.minutes(1)))
    func anAnswerIsAtMostAMegabyte() async throws {
        let (rig, contents) = try await rig(fileOf: 2_500_000)
        defer { rig.tearDown() }
        let greedy = try await rig.remote.fileBytes(itemID: rig.a.id, offset: 0, length: .max)
        #expect(greedy.data.count == MediaRead.maximumLength)
        #expect(greedy.data == contents.prefix(MediaRead.maximumLength))
    }

    /// The request names an item. The file is the one the library says
    /// that item plays from — for a segment, its video's.
    @Test(.timeLimit(.minutes(1)))
    func aSegmentsBytesAreItsVideos() async throws {
        let (rig, contents) = try await rig(fileOf: 50_000)
        defer { rig.tearDown() }
        let bytes = try await rig.remote.fileBytes(itemID: rig.segment.id, offset: 100, length: 50)
        #expect(bytes == MediaBytes(total: 50_000, data: contents[100..<150]))
    }

    @Test(.timeLimit(.minutes(1)))
    func whatTheHostCannotReachIsAFailureNotAFile() async throws {
        let (rig, _) = try await rig(fileOf: 1_000)
        defer { rig.tearDown() }

        for itemID in [rig.unmounted.id, UUID()] {
            do {
                _ = try await rig.remote.fileBytes(itemID: itemID, offset: 0, length: 10)
                Issue.record("bytes came back for an item with no file in reach")
            } catch let error as RemoteError {
                guard case .failed = error else {
                    Issue.record("not the host's failure: \(error)")
                    continue
                }
            }
        }
        await #expect(throws: RemoteError.self) {
            _ = try await rig.remote.fileBytes(itemID: rig.a.id, offset: -1, length: 10)
        }
        // And the connection is none the worse: the next read is answered.
        #expect(try await rig.remote.fileBytes(itemID: rig.a.id, offset: 0, length: 10).data.count == 10)
        #expect(rig.remote.state == .connected)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRevokedDeviceGetsNoMoreOfTheFile() async throws {
        let (rig, _) = try await rig(fileOf: 1_000)
        defer { rig.tearDown() }
        #expect(try await rig.remote.fileBytes(itemID: rig.a.id, offset: 0, length: 10).data.count == 10)

        rig.door.isOpen = false
        do {
            _ = try await rig.remote.fileBytes(itemID: rig.a.id, offset: 10, length: 10)
            Issue.record("a revoked device was sent more of the file")
        } catch let error as RemoteError {
            guard case .refused = error else {
                Issue.record("not a refusal: \(error)")
                return
            }
        }
    }

    // MARK: - Through the relay

    @Test(.timeLimit(.minutes(1)))
    func aPlayerIsAnsweredInRanges() async throws {
        let (rig, contents) = try await rig(fileOf: 2_500_000)
        defer { rig.tearDown() }
        let url = try #require(try await rig.remote.playable(itemID: rig.a.id).url)
        let total = contents.count

        // What a player asks first: two bytes, to see that ranges work.
        let (probe, two) = try await fetch(url, range: "bytes=0-1")
        #expect(probe.statusCode == 206)
        #expect(two == contents.prefix(2))
        #expect(probe.value(forHTTPHeaderField: "Content-Range") == "bytes 0-1/\(total)")
        #expect(probe.value(forHTTPHeaderField: "Content-Length") == "2")
        #expect(probe.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(probe.value(forHTTPHeaderField: "Content-Type") == "video/mp4")

        // From somewhere to the end: several fetches from the host, one answer.
        let (rest, tail) = try await fetch(url, range: "bytes=1000000-")
        #expect(rest.statusCode == 206)
        #expect(rest.value(forHTTPHeaderField: "Content-Range") == "bytes 1000000-\(total - 1)/\(total)")
        #expect(tail == contents.suffix(from: 1_000_000))

        // A piece that crosses from one fetch into the next.
        let (_, straddle) = try await fetch(url, range: "bytes=524000-525000")
        #expect(straddle == contents[524_000...525_000])

        // The last so many bytes.
        let (last, end) = try await fetch(url, range: "bytes=-100")
        #expect(last.statusCode == 206)
        #expect(last.value(forHTTPHeaderField: "Content-Range") == "bytes \(total - 100)-\(total - 1)/\(total)")
        #expect(end == contents.suffix(100))

        // Past the end of the file by its last byte: cut to what there is.
        let (over, short) = try await fetch(url, range: "bytes=\(total - 10)-\(total + 500)")
        #expect(over.statusCode == 206)
        #expect(short == contents.suffix(10))
    }

    @Test(.timeLimit(.minutes(1)))
    func withNoRangeTheWholeFileComes() async throws {
        let (rig, contents) = try await rig(fileOf: 1_200_000)
        defer { rig.tearDown() }
        let url = try #require(try await rig.remote.playable(itemID: rig.a.id).url)

        let (response, body) = try await fetch(url)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "\(contents.count)")
        #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(body == contents)

        let (head, nothing) = try await fetch(url, method: "HEAD")
        #expect(head.statusCode == 200)
        #expect(head.value(forHTTPHeaderField: "Content-Length") == "\(contents.count)")
        #expect(head.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(nothing.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func whatIsNotThereIsSaidPlainly() async throws {
        let (rig, contents) = try await rig(fileOf: 5_000)
        defer { rig.tearDown() }
        let url = try #require(try await rig.remote.playable(itemID: rig.a.id).url)
        let folder = url.deletingLastPathComponent()

        // A range the file does not have.
        let (beyond, _) = try await fetch(url, range: "bytes=\(contents.count)-")
        #expect(beyond.statusCode == 416)
        #expect(beyond.value(forHTTPHeaderField: "Content-Range") == "bytes */\(contents.count)")

        // An item the host has no file for, and one it has never heard of.
        let (unreachable, _) = try await fetch(folder.appendingPathComponent("\(rig.unmounted.id.uuidString).mp4"))
        #expect(unreachable.statusCode == 502)
        let (unknown, _) = try await fetch(folder.appendingPathComponent("\(UUID().uuidString).mp4"))
        #expect(unknown.statusCode == 502)

        // Not an item's address at all.
        let (notAnItem, _) = try await fetch(folder.appendingPathComponent("etc/passwd"))
        #expect(notAnItem.statusCode == 404)
        let (word, _) = try await fetch(folder.appendingPathComponent("hello.mp4"))
        #expect(word.statusCode == 404)

        // Only reading.
        let (post, _) = try await fetch(url, method: "POST")
        #expect(post.statusCode == 405)
    }

    /// The token in the address is what lets a program on this Mac read
    /// the item. Without it, knowing the port and the item's id — both
    /// of which other programs here can find out — gets nothing.
    @Test(.timeLimit(.minutes(1)))
    func withoutTheTokenAnItemsIdGetsNothing() async throws {
        let (rig, _) = try await rig(fileOf: 5_000)
        defer { rig.tearDown() }
        let url = try #require(try await rig.remote.playable(itemID: rig.a.id).url)
        let port = try #require(url.port)
        let name = url.lastPathComponent
        let token = url.deletingLastPathComponent().lastPathComponent
        #expect(token.count == 32)

        for guess in ["", String(repeating: "0", count: 32), String(token.dropLast()) + "x", token.uppercased() + "0"] {
            let address = try #require(URL(string: "http://127.0.0.1:\(port)/\(guess)/\(name)".replacingOccurrences(of: "//\(name)", with: "/\(name)")))
            let (response, body) = try await fetch(address)
            #expect(response.statusCode == 404, "\(address.path) was answered")
            #expect(body.isEmpty)
        }
        // Another service's relay has another token.
        let other = RemoteLibraryService(endpoint: rig.endpoint, libraryID: rig.libraryID)
        defer { other.close() }
        let elsewhere = try #require(try await other.playable(itemID: rig.a.id).url)
        #expect(elsewhere.deletingLastPathComponent().lastPathComponent != token)
    }

    /// A player keeps its connection and asks again on it.
    @Test(.timeLimit(.minutes(1)))
    func oneConnectionCarriesOneRequestAfterAnother() async throws {
        let (rig, contents) = try await rig(fileOf: 700_000)
        defer { rig.tearDown() }
        let url = try #require(try await rig.remote.playable(itemID: rig.a.id).url)
        let port = try #require(url.port)

        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let ready = OneShot<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.succeed(())
            case .failed(let error): ready.fail(error)
            default: break
            }
        }
        connection.start(queue: .global())
        defer { connection.cancel() }
        try await ready.value

        func ask(_ range: String, expecting body: Data) async throws {
            let head = "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=\(range)\r\n\r\n"
            let sent = OneShot<Void>()
            connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
                if let error { sent.fail(error) } else { sent.succeed(()) }
            })
            try await sent.value
            var received = Data()
            let end = Data("\r\n\r\n".utf8)
            while true {
                if let found = received.range(of: end) {
                    let text = String(decoding: received[..<found.lowerBound], as: UTF8.self)
                    #expect(text.hasPrefix("HTTP/1.1 206"))
                    if received.count - found.upperBound >= body.count {
                        #expect(Data(received[found.upperBound...]) == body, "range \(range)")
                        return
                    }
                }
                let chunk = OneShot<Data>()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, error in
                    if let data, !data.isEmpty { chunk.succeed(data) } else { chunk.fail(error ?? ChannelError.closed) }
                }
                received.append(try await chunk.value)
            }
        }
        try await ask("0-9", expecting: contents.prefix(10))
        try await ask("600000-699999", expecting: contents.suffix(100_000))
        try await ask("5-5", expecting: contents[5...5])
    }

    @Test(.timeLimit(.minutes(1)))
    func whenTheServiceIsClosedItsRelayIsGone() async throws {
        let (rig, _) = try await rig(fileOf: 5_000)
        defer { rig.tearDown() }
        let url = try #require(try await rig.remote.playable(itemID: rig.a.id).url)
        #expect(try await fetch(url, range: "bytes=0-1").0.statusCode == 206)

        rig.remote.close()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) { _ = try await fetch(url, range: "bytes=0-1") }
        // And it does not come back for the asking: a closed service
        // answers nothing.
        await #expect(throws: RemoteError.self) { _ = try await rig.remote.playable(itemID: rig.a.id) }
    }

    // MARK: - Reading a request

    @Test func aRangeIsReadAsAPlayerMeansIt() {
        typealias Span = MediaRelay.Span
        #expect(MediaRelay.span(of: nil, total: 100) == .whole)
        #expect(MediaRelay.span(of: "bytes=0-1", total: 100) == .part(0...1))
        #expect(MediaRelay.span(of: "bytes=10-", total: 100) == .part(10...99))
        #expect(MediaRelay.span(of: "bytes=10-500", total: 100) == .part(10...99))
        #expect(MediaRelay.span(of: "bytes=-10", total: 100) == .part(90...99))
        #expect(MediaRelay.span(of: "bytes=-500", total: 100) == .part(0...99))
        #expect(MediaRelay.span(of: "Bytes=5-5", total: 100) == .part(5...5))
        #expect(MediaRelay.span(of: "bytes=100-", total: 100) == .unsatisfiable)
        #expect(MediaRelay.span(of: "bytes=-0", total: 100) == .unsatisfiable)
        #expect(MediaRelay.span(of: "bytes=0-", total: 0) == .unsatisfiable)
        // What this does not read is answered with the whole file, as
        // the rules for ranges allow.
        #expect(MediaRelay.span(of: "bytes=0-1,5-6", total: 100) == .whole)
        #expect(MediaRelay.span(of: "bytes=9-3", total: 100) == .whole)
        #expect(MediaRelay.span(of: "items=0-1", total: 100) == .whole)
        #expect(MediaRelay.span(of: "bytes=abc-", total: 100) == .whole)
    }

    @Test func aRequestsHeadIsRead() {
        let head = "GET /token/item.mp4 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nrange:  bytes=0-1 \r\nConnection: Close"
        #expect(MediaRelay.parse(Data(head.utf8))
            == MediaRelay.Request(method: "GET", path: "/token/item.mp4", range: "bytes=0-1", closes: true))
        #expect(MediaRelay.parse(Data("HEAD /a HTTP/1.0".utf8))
            == MediaRelay.Request(method: "HEAD", path: "/a", range: nil, closes: false))
        #expect(MediaRelay.parse(Data("hello".utf8)) == nil)
        #expect(MediaRelay.parse(Data("GET /a b c HTTP/1.1".utf8)) == nil)
        #expect(MediaRelay.parse(Data("GET /a SPDY/3".utf8)) == nil)
        #expect(MediaRelay.parse(Data([0xFF, 0xFE, 0x00])) == nil)
    }

    // MARK: - Thumbnails

    /// The host has made a thumbnail; the other Mac is sent it, and need
    /// not fetch the video to make its own.
    @Test(.timeLimit(.minutes(1)))
    func theHostsThumbnailIsSentAsItIs() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        let libraryID = try #require(try rig.library.info()?.libraryID)
        let file = ThumbnailStore.url(libraryID: libraryID, itemID: rig.a.id)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        #expect(try await rig.local.storedThumbnail(itemID: rig.a.id) == nil)
        #expect(try await rig.remote.storedThumbnail(itemID: rig.a.id) == nil)

        // What stands for a JPEG here: it ends as one does.
        let jpeg = Data([0xFF, 0xD8]) + pattern(40_000) + Data([0xFF, 0xD9])
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: file)
        #expect(try await rig.local.storedThumbnail(itemID: rig.a.id) == jpeg)
        #expect(try await rig.remote.storedThumbnail(itemID: rig.a.id) == jpeg)
        #expect(try await rig.remote.storedThumbnail(itemID: rig.b.id) == nil)

        // One cut off part-way through being written is not sent.
        try jpeg.dropLast(100).write(to: file)
        #expect(try await rig.remote.storedThumbnail(itemID: rig.a.id) == nil)
    }

    // MARK: - A real video

    /// What all of the above is for: a player on this Mac opens the
    /// relay's address, plays, and seeks, with the file on the host.
    @Test(.writesVideo, .timeLimit(.minutes(2)))
    func aPlayerPlaysAndSeeksThroughTheRelay() async throws {
        let rig = try await RemoteRig()
        defer { rig.tearDown() }
        try await DemoMediaFactory.writeVideo(to: rig.root.appendingPathComponent("set/a.mp4"), seconds: 6)
        let url = try #require(try await rig.remote.playable(itemID: rig.a.id).url)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 6) < 0.5, "the video is \(duration) seconds long through the relay")

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        defer { player.replaceCurrentItem(with: nil) }
        for _ in 0..<300 where item.status == .unknown { try await Task.sleep(for: .milliseconds(20)) }
        #expect(item.status == .readyToPlay, "\(String(describing: item.error))")

        let target = CMTime(seconds: 4, preferredTimescale: 600)
        let landed = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(landed)
        #expect(abs(player.currentTime().seconds - 4) < 0.05)

        // And a frame can be taken, which is how a thumbnail is made
        // when the host has none.
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image
        #expect(frame.width > 0)
    }
}
