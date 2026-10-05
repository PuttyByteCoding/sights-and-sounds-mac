import Foundation
import Testing

import SightsAndSoundsKit
@testable import SightsAndSoundsRemote

/// How a Mac comes to be let in, and put out again: a host on loopback,
/// its devices in a file in a temporary folder, and the host's user
/// played by an `Approver`.
@Suite struct PairingTests {
    /// The host's user, asked whether to let a device in.
    final class Approver: @unchecked Sendable {
        private let lock = NSLock()
        private var answers = true
        private var questions: [PairingAsk] = []
        private var held: OneShot<Void>?

        var answer: Bool {
            get { lock.withLock { answers } }
            set { lock.withLock { answers = newValue } }
        }
        var asked: [PairingAsk] { lock.withLock { questions } }

        /// From here on a question is left unanswered until `release`.
        func hold() { lock.withLock { held = OneShot<Void>() } }
        func release() { lock.withLock { held }?.succeed(()) }

        func ask(_ question: PairingAsk) async -> Bool {
            let waiting = lock.withLock { () -> OneShot<Void>? in
                questions.append(question)
                return held
            }
            try? await waiting?.value
            return answer
        }
    }

    final class Rig: @unchecked Sendable {
        let folder: URL
        let file: URL
        let approver = Approver()
        let libraryID = UUID()
        let local: LocalLibraryService
        private(set) var store: DeviceStore
        private(set) var host: RemoteHost

        init() async throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("sas-pairing-\(UUID().uuidString)", isDirectory: true)
            file = folder.appendingPathComponent("remote/approved-devices.json")
            let library = try LibraryDatabase.openInMemory()
            try library.ensureInfo(name: "Rig")
            local = LocalLibraryService(library: library)
            store = try DeviceStore(file: file)
            host = Self.host(store: store, approver: approver, libraryID: libraryID, local: local)
            try await host.start()
        }

        private static func host(
            store: DeviceStore, approver: Approver, libraryID: UUID, local: LocalLibraryService
        ) -> RemoteHost {
            RemoteHost(
                store: store,
                hostName: { "The Host" },
                libraries: { [RemoteLibraryInfo(id: libraryID, name: "Rig")] },
                service: { $0 == libraryID ? local : nil },
                approve: { await approver.ask($0) })
        }

        /// The app quit and opened again: a new host over the same file.
        func restart() async throws {
            await host.stop()
            store = try DeviceStore(file: file)
            host = Self.host(store: store, approver: approver, libraryID: libraryID, local: local)
            try await host.start()
        }

        /// A code as the other Mac gets it: as text.
        func code(lifetime: Duration = .seconds(600)) async throws -> PairingCode {
            let offered = try await host.beginPairing(address: "127.0.0.1", lifetime: lifetime)
            return try #require(PairingCode(text: offered.text))
        }

        func pair(_ name: String) async throws -> SavedHost {
            try await RemotePairing.pair(with: try await code(), as: name)
        }

        func tearDown() async {
            await host.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func withRig(_ body: (Rig) async throws -> Void) async throws {
        let rig = try await Rig()
        do {
            try await body(rig)
        } catch {
            await rig.tearDown()
            throw error
        }
        await rig.tearDown()
    }

    private func eventually(_ what: String, _ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("\(what): never happened")
    }

    /// Whether this Mac is welcomed by the host as that device.
    private func isWelcome(_ saved: SavedHost) async -> Bool {
        (try? await RemoteLibraryService.welcome(from: saved.endpoint, timeout: .seconds(3))) != nil
    }

    // MARK: - The code

    @Test func theCodeSurvivesBeingText() throws {
        let code = PairingCode.random(address: "192.168.1.20", port: 50_123, hostName: "The Host")
        #expect(code.secret.count == 32)
        #expect(PairingCode(text: code.text) == code)
        #expect(code.text.hasPrefix("SAS-PAIR-"))
        let hasSpace = code.text.contains { $0.isWhitespace }
        #expect(!hasSpace)

        // As it comes out of a message that wrapped it, or a careless copy.
        let text = code.text
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        #expect(PairingCode(text: "  \(text[..<middle])\n  \(text[middle...])\n") == code)
        #expect(PairingCode(text: "sas-pair-" + text.dropFirst(9)) == code)

        // Two codes for the same host are different secrets.
        #expect(PairingCode.random(address: "192.168.1.20", port: 50_123, hostName: "The Host") != code)
    }

    @Test func whatIsNotACodeIsNotReadAsOne() {
        let code = PairingCode.random(address: "192.168.1.20", port: 50_123, hostName: "The Host")
        #expect(PairingCode(text: "") == nil)
        #expect(PairingCode(text: "SAS-PAIR-") == nil)
        #expect(PairingCode(text: "hello") == nil)
        #expect(PairingCode(text: "SAS-PAIR-not base64 at all!") == nil)
        #expect(PairingCode(text: String(code.text.dropLast(4))) == nil, "a code cut short")
        #expect(PairingCode(text: code.text + "AAAA") == nil, "a code with something on the end")
        #expect(PairingCode(text: String(code.text.dropFirst(9))) == nil, "a code without its front")
        var zeroPort = code
        zeroPort.port = 0
        #expect(PairingCode(text: zeroPort.text) == nil)
    }

    @Test func aLongHostNameIsCutNotRefused() throws {
        let code = PairingCode.random(address: "10.0.0.2", port: 9, hostName: String(repeating: "né", count: 200))
        #expect(code.hostName.count == 48)
        #expect(PairingCode(text: code.text) == code)
    }

    // MARK: - Pairing

    @Test(.timeLimit(.minutes(1)))
    func aMacIsPairedAndThenConnectsAsItself() async throws {
        try await withRig { rig in
            let saved = try await rig.pair("Studio MacBook")

            #expect(rig.approver.asked == [PairingAsk(deviceName: "Studio MacBook", address: "127.0.0.1")])
            #expect(saved.name == "The Host")
            #expect(saved.address == "127.0.0.1")
            #expect(await rig.host.port == saved.port)
            let devices = rig.host.devices
            #expect(devices.map(\.name) == ["Studio MacBook"])
            #expect(devices.first?.id == saved.id)
            #expect(devices.first?.lastConnectedAt == nil)

            // With what it was given, and nothing of the code, it is
            // in — at once: the host had its key in place before it
            // said yes.
            #expect(await isWelcome(saved))
            let welcome = try await RemoteLibraryService.welcome(from: saved.endpoint)
            #expect(welcome.hostName == "The Host")
            #expect(welcome.libraries == [RemoteLibraryInfo(id: rig.libraryID, name: "Rig")])
            let remote = RemoteLibraryService(endpoint: saved.endpoint, libraryID: rig.libraryID)
            defer { remote.close() }
            #expect(try await remote.pendingDuplicateCount() == 0)
            #expect(rig.host.devices.first?.lastConnectedAt != nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aNoIsANoAndTheCodeIsSpent() async throws {
        try await withRig { rig in
            rig.approver.answer = false
            let code = try await rig.code()

            await #expect(throws: PairingError.declined("The other Mac did not allow this one.")) {
                _ = try await RemotePairing.pair(with: code, as: "Somebody's Mac")
            }
            #expect(rig.approver.asked.count == 1)
            #expect(rig.host.devices.isEmpty)
            #expect(await rig.host.pairingCode == nil)

            // Asking again with the same code does not put the question
            // again, even to a host that would now say yes.
            rig.approver.answer = true
            await #expect(throws: PairingError.self) {
                _ = try await RemotePairing.pair(with: code, as: "Somebody's Mac")
            }
            #expect(rig.approver.asked.count == 1)
            #expect(rig.host.devices.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCodeIsGoodForOneDevice() async throws {
        try await withRig { rig in
            let code = try await rig.code()
            let first = try await RemotePairing.pair(with: code, as: "First")

            await #expect(throws: PairingError.self) {
                _ = try await RemotePairing.pair(with: code, as: "Second")
            }
            #expect(rig.approver.asked.map(\.deviceName) == ["First"])
            #expect(rig.host.devices.map(\.name) == ["First"])

            // And soon the secret is not even a key: no connection.
            await eventually("the code's secret stops being a key") {
                let connection = FrameConnection(host: "127.0.0.1", port: code.port, key: code.key)
                defer { Task { await connection.close() } }
                return (try? await connection.open(timeout: .seconds(3))) == nil
            }
            await eventually("the first is still welcome") { await isWelcome(first) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCodeRunsOut() async throws {
        try await withRig { rig in
            let code = try await rig.code(lifetime: .milliseconds(200))
            await eventually("the code ran out") { await rig.host.pairingCode == nil }

            await #expect(throws: PairingError.self) {
                _ = try await RemotePairing.pair(with: code, as: "Too Late")
            }
            #expect(rig.approver.asked.isEmpty)
            #expect(rig.host.devices.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewCodeReplacesTheOld() async throws {
        try await withRig { rig in
            let old = try await rig.code()
            let new = try await rig.code()
            #expect(old.secret != new.secret)
            #expect(await rig.host.pairingCode == new)

            await #expect(throws: PairingError.self) {
                _ = try await RemotePairing.pair(with: old, as: "With The Old")
            }
            #expect(rig.approver.asked.isEmpty)
            let saved = try await RemotePairing.pair(with: new, as: "With The New")
            #expect(rig.host.devices.map(\.id) == [saved.id])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCodeWithdrawnIsNoGood() async throws {
        try await withRig { rig in
            let code = try await rig.code()
            await rig.host.endPairing()
            #expect(await rig.host.pairingCode == nil)
            await #expect(throws: PairingError.self) {
                _ = try await RemotePairing.pair(with: code, as: "Too Late")
            }
            #expect(rig.approver.asked.isEmpty)
        }
    }

    /// The code is for one device. While the host's user is looking at
    /// the question about it, a second device with the same code is not
    /// queued up behind: it is told no.
    @Test(.timeLimit(.minutes(1)))
    func onlyOneDeviceIsAskedAboutAtATime() async throws {
        try await withRig { rig in
            rig.approver.hold()
            let code = try await rig.code()
            let first = Task { try await RemotePairing.pair(with: code, as: "First") }
            await eventually("the host's user is asked") { rig.approver.asked.count == 1 }

            await #expect(throws: PairingError.self) {
                _ = try await RemotePairing.pair(with: code, as: "Second")
            }
            #expect(rig.approver.asked.count == 1)

            rig.approver.release()
            let saved = try await first.value
            #expect(rig.host.devices.map(\.id) == [saved.id])
        }
    }

    /// A code that runs out while the question is up: the device asked
    /// in time, and the answer still counts.
    @Test(.timeLimit(.minutes(1)))
    func anAnswerGivenAfterTheCodeRanOutStillCounts() async throws {
        try await withRig { rig in
            rig.approver.hold()
            let code = try await rig.code()
            let asking = Task { try await RemotePairing.pair(with: code, as: "In Time") }
            await eventually("the host's user is asked") { rig.approver.asked.count == 1 }
            await rig.host.pairingTimeIsUp()
            #expect(await rig.host.pairingCode == code, "the code went while the question was up")

            rig.approver.release()
            let saved = try await asking.value
            #expect(rig.host.devices.map(\.id) == [saved.id])
            #expect(await rig.host.pairingCode == nil)
        }
    }

    /// Turned off while the question is up: a yes to it lets no one in.
    @Test(.timeLimit(.minutes(1)))
    func aYesAfterRemoteAccessWasTurnedOffLetsNoOneIn() async throws {
        try await withRig { rig in
            rig.approver.hold()
            let code = try await rig.code()
            let asking = Task { try await RemotePairing.pair(with: code, as: "Mid Question") }
            await eventually("the host's user is asked") { rig.approver.asked.count == 1 }

            await rig.host.stop()
            rig.approver.release()
            await #expect(throws: PairingError.self) { _ = try await asking.value }
            #expect(rig.host.devices.isEmpty)
        }
    }

    /// A device already approved has a key the listener holds, so it can
    /// connect and send anything — a request to pair among them. It does
    /// not hold the code's secret, and is not asked about.
    @Test(.timeLimit(.minutes(1)))
    func anApprovedDeviceCannotAskToBePairedAgain() async throws {
        try await withRig { rig in
            let saved = try await rig.pair("First")
            let live = try await rig.code()

            let connection = FrameConnection(host: "127.0.0.1", port: saved.port, key: saved.endpoint.key)
            try await connection.open(timeout: .seconds(5))
            for proof in [Data(), Data(repeating: 0, count: 32), PairingCode.proof(secret: saved.endpoint.token, deviceName: "Again")] {
                let again = FrameConnection(host: "127.0.0.1", port: saved.port, key: saved.endpoint.key)
                try await again.open(timeout: .seconds(5))
                try await again.send(Frame(
                    kind: RemoteProtocol.Kind.pair,
                    payload: try RemoteProtocol.encode(PairRequest(deviceName: "Again", proof: proof))))
                let reply = try await again.receive()
                #expect(reply.kind == RemoteProtocol.Kind.refusal)
                await again.close()
            }
            await connection.close()
            #expect(rig.approver.asked.map(\.deviceName) == ["First"])
            #expect(rig.host.devices.count == 1)
            // And the code it could not use is still good for the Mac it
            // was made for.
            let second = try await RemotePairing.pair(with: live, as: "Second")
            #expect(Set(rig.host.devices.map(\.id)) == [saved.id, second.id])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCodeForSomewhereElseIsNotTried() async throws {
        let code = PairingCode.random(address: "203.0.113.9", port: 50_000, hostName: "Far Away")
        await #expect(throws: PairingError.notOnThisNetwork("203.0.113.9")) {
            _ = try await RemotePairing.pair(with: code, as: "This Mac")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func nobodyAnsweringIsNotForever() async throws {
        try await withRig { rig in
            rig.approver.hold()
            let code = try await rig.code()
            await #expect(throws: PairingError.timedOut) {
                _ = try await RemotePairing.pair(with: code, as: "Impatient", patience: .milliseconds(400))
            }
            rig.approver.release()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func pairingNeedsRemoteAccessOnAndALocalAddress() async throws {
        try await withRig { rig in
            await #expect(throws: RemoteHostError.notALocalAddress("203.0.113.9")) {
                _ = try await rig.host.beginPairing(address: "203.0.113.9")
            }
            await rig.host.stop()
            await #expect(throws: RemoteHostError.notRunning) {
                _ = try await rig.host.beginPairing(address: "127.0.0.1")
            }
        }
    }

    // MARK: - Revoking

    @Test(.timeLimit(.minutes(1)))
    func aRevokedDeviceIsOutAndTheOtherStaysIn() async throws {
        try await withRig { rig in
            let first = try await rig.pair("First")
            let second = try await rig.pair("Second")
            #expect(rig.host.devices.map(\.name) == ["First", "Second"])
            await eventually("both are welcome") { await isWelcome(first) }
            await eventually("both are welcome") { await isWelcome(second) }
            let remote = RemoteLibraryService(endpoint: first.endpoint, libraryID: rig.libraryID)
            defer { remote.close() }
            #expect(try await remote.pendingDuplicateCount() == 0)

            try await rig.host.revoke(first.id)

            #expect(rig.host.devices.map(\.name) == ["Second"])
            // Not on the connection it had, and not on a new one: its
            // key is no longer a key.
            await #expect(throws: RemoteError.self) { _ = try await remote.pendingDuplicateCount() }
            let connection = FrameConnection(host: "127.0.0.1", port: first.port, key: first.endpoint.key)
            await #expect(throws: ChannelError.self) { try await connection.open(timeout: .seconds(3)) }
            #expect(await isWelcome(first) == false)
            await eventually("the other is still welcome") { await isWelcome(second) }

            // Revoking what is not there is not an error.
            try await rig.host.revoke(first.id)
        }
    }

    // MARK: - What is kept

    @Test(.timeLimit(.minutes(1)))
    func approvalsAndThePortSurviveARestart() async throws {
        try await withRig { rig in
            let saved = try await rig.pair("Studio MacBook")
            await eventually("welcomed") { await isWelcome(saved) }
            let port = await rig.host.port

            try await rig.restart()

            #expect(await rig.host.port == port, "the host moved, and the other Mac's address with it")
            #expect(rig.host.devices.map(\.name) == ["Studio MacBook"])
            await eventually("welcomed again after the restart") { await isWelcome(saved) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func turningRemoteAccessOffKeepsTheApprovals() async throws {
        try await withRig { rig in
            let saved = try await rig.pair("Studio MacBook")
            await eventually("welcomed") { await isWelcome(saved) }
            let port = await rig.host.port

            await rig.host.stop()
            #expect(await rig.host.isRunning == false)
            #expect(await rig.host.port == nil)
            #expect(await isWelcome(saved) == false)
            #expect(rig.host.devices.count == 1)

            try await rig.host.start()
            #expect(await rig.host.port == port)
            await eventually("welcomed again") { await isWelcome(saved) }
        }
    }

    /// Remote access switched on twice in the same moment, or on and
    /// straight off: it ends as it was last asked to be, on one port.
    @Test(.timeLimit(.minutes(1)))
    func turnedOnTwiceAtOnceItIsOneHostAndTurnedOffItIsOff() async throws {
        try await withRig { rig in
            let port = await rig.host.port
            await rig.host.stop()

            async let first = rig.host.start()
            async let second = rig.host.start()
            let ports = try await [first, second]
            #expect(ports == [port, port].compactMap { $0 })
            #expect(await rig.host.isRunning)

            await rig.host.stop()
            let starting = Task { try await rig.host.start() }
            await rig.host.stop()
            _ = try? await starting.value
            // Whichever got there first, a stop asked for after the
            // start leaves it off or is followed by nothing on.
            await rig.host.stop()
            #expect(await rig.host.isRunning == false)
            let connection = FrameConnection(
                host: "127.0.0.1", port: port ?? 0, key: ChannelKey.random(identity: "anyone"))
            await #expect(throws: ChannelError.self) { try await connection.open(timeout: .seconds(2)) }
        }
    }

    /// The file holds what lets a device in, so only the user reads it;
    /// and it does not hold the device's token, only what a token is
    /// checked against.
    @Test(.timeLimit(.minutes(1)))
    func theHostsFileIsTheUsersAloneAndHoldsNoToken() async throws {
        try await withRig { rig in
            let saved = try await rig.pair("Studio MacBook")
            let attributes = try FileManager.default.attributesOfItem(atPath: rig.file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let folder = try FileManager.default.attributesOfItem(atPath: rig.file.deletingLastPathComponent().path)
            #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)

            let text = try String(contentsOf: rig.file, encoding: .utf8)
            #expect(text.contains("Studio MacBook"))
            #expect(!text.contains(saved.endpoint.token.base64EncodedString()))
            // Nothing left beside it from the writing of it.
            let beside = try FileManager.default.contentsOfDirectory(atPath: rig.file.deletingLastPathComponent().path)
            #expect(beside == [rig.file.lastPathComponent])

            // Loosened by something else, it is tightened when next read.
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.file.path)
            _ = try DeviceStore(file: rig.file)
            let after = try FileManager.default.attributesOfItem(atPath: rig.file.path)
            #expect((after[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    /// A file that is there and will not read is not "no devices". Read
    /// as that, the next approval would write over every one before it.
    @Test func aFileThatCannotBeReadIsNotAnEmptyOne() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-pairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("approved-devices.json")
        try Data("{ not what was written".utf8).write(to: file)

        #expect(throws: (any Error).self) { _ = try DeviceStore(file: file) }
        #expect(throws: (any Error).self) { _ = try HostStore(file: file) }
        #expect(try Data(contentsOf: file) == Data("{ not what was written".utf8))
    }

    @Test func onlyTheRightTokenIsTheDevices() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-pairing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try DeviceStore(file: folder.appendingPathComponent("approved-devices.json"))
        let (a, tokenA) = try store.approve(name: "A")
        let (b, tokenB) = try store.approve(name: "B")

        #expect(store.approves(a.id, token: tokenA))
        #expect(store.approves(b.id, token: tokenB))
        #expect(!store.approves(a.id, token: tokenB), "another device's token")
        #expect(!store.approves(a.id, token: Data()))
        #expect(!store.approves(a.id, token: a.tokenHash), "what the file holds is not a token")
        #expect(!store.approves(UUID(), token: tokenA))
        #expect(a.key != b.key)
        #expect(a.key.key.count == 32)

        #expect(try store.revoke(a.id))
        #expect(!store.approves(a.id, token: tokenA))
        #expect(store.approves(b.id, token: tokenB))
        #expect(try store.revoke(a.id) == false)
    }

    @Test func whenADeviceWasLastHereIsWrittenAtMostOnceAMinute() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-pairing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try DeviceStore(file: folder.appendingPathComponent("approved-devices.json"))
        let (device, _) = try store.approve(name: "A")
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(store.connected(device.id, at: start))
        #expect(!store.connected(device.id, at: start.addingTimeInterval(30)))
        #expect(store.devices.first?.lastConnectedAt == start)
        #expect(store.connected(device.id, at: start.addingTimeInterval(61)))
        #expect(store.devices.first?.lastConnectedAt == start.addingTimeInterval(61))
        #expect(!store.connected(UUID(), at: start))
    }

    /// The name is the device's word for itself, and is put in front of
    /// the host's user in a question.
    @Test func aDevicesNameIsMadeFitToShow() {
        #expect(DeviceStore.presentable("Studio MacBook") == "Studio MacBook")
        #expect(DeviceStore.presentable("  padded  ") == "padded")
        #expect(DeviceStore.presentable("") == "A Mac with no name")
        #expect(DeviceStore.presentable(" \n\t ") == "A Mac with no name")
        #expect(DeviceStore.presentable("Your Mac\nAllow?\u{07}") == "Your MacAllow?")
        #expect(DeviceStore.presentable(String(repeating: "x", count: 500)).count == 64)
    }

    // MARK: - The client's hosts

    @Test func theClientsHostsAreKeptInAFileOfItsOwn() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-pairing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("remote/hosts.json")
        let store = try HostStore(file: file)
        #expect(store.hosts.isEmpty)

        func host(_ name: String, at seconds: TimeInterval) -> SavedHost {
            SavedHost(
                id: UUID(), name: name, address: "192.168.1.20", port: 50_000,
                pairedAt: Date(timeIntervalSince1970: seconds),
                key: ChannelKey.random(identity: "k"), token: Data(repeating: 7, count: 32))
        }
        let den = host("Den", at: 200), attic = host("Attic", at: 100)
        try store.save(den)
        try store.save(attic)
        #expect(store.hosts == [attic, den], "in the order they were paired")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try store.move(den.id, toAddress: "192.168.1.77", port: 50_001)
        let reopened = try HostStore(file: file)
        #expect(reopened.hosts.map(\.name) == ["Attic", "Den"])
        #expect(reopened.hosts.last?.endpoint.host == "192.168.1.77")
        #expect(reopened.hosts.last?.endpoint.port == 50_001)
        #expect(reopened.hosts.last?.endpoint.key == den.endpoint.key)
        #expect(reopened.hosts.last?.endpoint.deviceID == den.id)

        try reopened.remove(attic.id)
        #expect(try HostStore(file: file).hosts.map(\.name) == ["Den"])
    }

    // MARK: - This Mac's address

    @Test func thisMacsAddressesAreOnesAnotherMacCouldUse() {
        for address in RemoteAddress.ofThisMac() {
            #expect(RemoteAddress.isLocalNetwork(address), "\(address)")
            #expect(!address.hasPrefix("127."), "\(address) reaches only this Mac")
            #expect(address.split(separator: ".").count == 4, "\(address)")
        }
    }

    // MARK: - Watching

    @Test(.timeLimit(.minutes(1)))
    func whoeverWatchesTheHostHearsOfADevice() async throws {
        try await withRig { rig in
            let heard = OneShot<Void>()
            let watching = Task {
                for await _ in rig.host.changes() {
                    if !rig.host.devices.isEmpty { heard.succeed(()) }
                }
            }
            defer { watching.cancel() }
            try await Task.sleep(for: .milliseconds(50))
            _ = try await rig.pair("Studio MacBook")
            try await heard.value
        }
    }
}
