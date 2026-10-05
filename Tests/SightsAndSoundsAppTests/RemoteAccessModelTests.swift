import AppKit
import CoreImage
import Foundation
import SightsAndSoundsKit
import Testing

@testable import SightsAndSoundsApp
@testable import SightsAndSoundsRemote

/// Settings ▸ Remote Access, without the window: turning it on and off,
/// letting a Mac in with a code, putting one out, and what is said when
/// it cannot do what was asked.
@Suite @MainActor struct RemoteAccessModelTests {
    /// Whoever is at this Mac, asked about a device.
    @MainActor final class Person {
        var answer = true
        private(set) var asked: [PairingAsk] = []
        func ask(_ question: PairingAsk) async -> Bool {
            asked.append(question)
            return answer
        }
    }

    private func folder() -> URL {
        AppSettingsStore.testScratch.appendingPathComponent("remote-access-\(UUID().uuidString)", isDirectory: true)
    }

    private func model(_ file: URL, _ person: Person) -> RemoteAccessModel {
        RemoteAccessModel(
            file: file,
            offer: RemoteAccessModel.Offer(
                hostName: { "The Host" }, libraries: { [] }, service: { _ in nil }, turnedOff: {}),
            ask: { await person.ask($0) })
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), "\(what): never happened")
    }

    // MARK: - On and off

    @Test(.timeLimit(.minutes(1)))
    func turnedOnItListensAndIsOnAgainNextTime() async throws {
        let file = folder().appendingPathComponent("approved-devices.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = model(file, Person())
        #expect(first.isAvailable && !first.isOn && first.port == nil)
        await first.startIfLeftOn()
        #expect(!first.isOn, "it was never turned on, and came on by itself")

        await first.setOn(true)
        #expect(first.isOn && first.problem == nil)
        let port = try #require(first.port)

        // The app quits and is opened again.
        await first.shutDown()
        #expect(!first.isOn)
        let second = model(file, Person())
        #expect(!second.isOn)
        await second.startIfLeftOn()
        #expect(second.isOn)
        #expect(second.port == port, "the port moved, and every paired Mac's address with it")

        // Turned off, it stays off.
        await second.setOn(false)
        #expect(!second.isOn && second.port == nil)
        let third = model(file, Person())
        await third.startIfLeftOn()
        #expect(!third.isOn)
    }

    // MARK: - Pairing

    @Test(.timeLimit(.minutes(1)))
    func aMacIsLetInWithACodeAndPutOutAgain() async throws {
        let file = folder().appendingPathComponent("approved-devices.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let person = Person()
        let model = model(file, person)
        defer { Task { await model.shutDown() } }

        // Off: no code.
        await model.beginPairing(address: "127.0.0.1")
        #expect(model.pairingCode == nil && model.problem != nil)

        await model.setOn(true)
        await model.beginPairing(address: "127.0.0.1")
        let offered = try #require(model.pairingCode)
        #expect(model.problem == nil)

        // The other Mac is given the code as text.
        let code = try #require(PairingCode(text: offered.text))
        let saved = try await RemotePairing.pair(with: code, as: "Studio MacBook")

        #expect(person.asked == [PairingAsk(deviceName: "Studio MacBook", address: "127.0.0.1")])
        // The pane follows by itself: nothing here asks it to look.
        await eventually("the Mac is listed") { model.devices.map(\.name) == ["Studio MacBook"] }
        await eventually("the code is gone") { model.pairingCode == nil }
        #expect(try await RemoteLibraryService.welcome(from: saved.endpoint).hostName == "The Host")
        await eventually("it is seen to have connected") { model.devices.first?.lastConnectedAt != nil }

        await model.revoke(saved.id)
        #expect(model.devices.isEmpty)
        await #expect(throws: RemoteError.self) {
            _ = try await RemoteLibraryService.welcome(from: saved.endpoint, timeout: .seconds(3))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aNoLetsNoOneIn() async throws {
        let file = folder().appendingPathComponent("approved-devices.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let person = Person()
        person.answer = false
        let model = model(file, person)
        defer { Task { await model.shutDown() } }
        await model.setOn(true)
        await model.beginPairing(address: "127.0.0.1")
        let code = try #require(model.pairingCode)

        await #expect(throws: PairingError.self) {
            _ = try await RemotePairing.pair(with: code, as: "Somebody")
        }
        #expect(person.asked.count == 1)
        await eventually("the code is gone") { model.pairingCode == nil }
        #expect(model.devices.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func closingTheCodeWithdrawsIt() async throws {
        let file = folder().appendingPathComponent("approved-devices.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let person = Person()
        let model = model(file, person)
        defer { Task { await model.shutDown() } }
        await model.setOn(true)
        await model.beginPairing(address: "127.0.0.1")
        let code = try #require(model.pairingCode)

        await model.endPairing()
        #expect(model.pairingCode == nil)
        await #expect(throws: PairingError.self) {
            _ = try await RemotePairing.pair(with: code, as: "Too Late")
        }
        #expect(person.asked.isEmpty)
    }

    // MARK: - When it cannot

    /// A list that will not read is not an empty list. Nothing is turned
    /// on over it, and it is left exactly as it was found.
    @Test func aListThatCannotBeReadLeavesRemoteAccessOff() async throws {
        let file = folder().appendingPathComponent("approved-devices.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("{ not what was written".utf8).write(to: file)

        let model = model(file, Person())
        #expect(!model.isAvailable)
        #expect(model.problem?.contains("could not be read") == true)
        await model.setOn(true)
        await model.startIfLeftOn()
        #expect(!model.isOn)
        #expect(try Data(contentsOf: file) == Data("{ not what was written".utf8))
    }

    /// The port is kept so the other Macs' addresses stay good. If
    /// something else has it, that is said, and another can be chosen.
    @Test(.timeLimit(.minutes(1)))
    func aPortSomethingElseHasIsSaidAndAnotherCanBeUsed() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let holder = model(folder.appendingPathComponent("holder.json"), Person())
        await holder.setOn(true)
        defer { Task { await holder.shutDown() } }
        let taken = try #require(holder.port)

        // A list whose host last listened on that same port.
        let file = folder.appendingPathComponent("approved-devices.json")
        try DeviceStore(file: file).setPort(taken)
        let model = model(file, Person())
        defer { Task { await model.shutDown() } }

        await model.setOn(true)
        #expect(!model.isOn)
        #expect(model.portIsTaken)
        #expect(model.problem?.contains("\(taken)") == true)

        await model.useAnotherPort()
        #expect(model.isOn && !model.portIsTaken && model.problem == nil)
        #expect(model.port != nil && model.port != taken)
    }

    // MARK: - The app's libraries

    private func registered(_ app: AppModel) throws -> (LibraryRef, URL) {
        let url = AppSettingsStore.testScratch
            .appendingPathComponent("remote-offer-\(UUID().uuidString).sqlite")
        let library = try LibraryDatabase.open(at: url)
        try library.ensureInfo(name: "Offered")
        let backup = try library.backup(
            into: AppSettingsStore.testScratch.appendingPathComponent("remote-offer-backups-\(UUID().uuidString)"))
        let ref = try #require(app.appDatabase).register(library)
        try library.close()
        app.refresh()
        return (ref, backup)
    }

    /// What another Mac is offered is the app's own list of libraries,
    /// each answered by the library itself. And a library another Mac
    /// has been given is in use: it is not restored or removed under it.
    @Test(.timeLimit(.minutes(1)))
    func theAppsLibrariesAreWhatAnotherMacIsOffered() async throws {
        let app = AppModel()
        let (ref, backup) = try registered(app)
        app.askAboutAMac = { _ in true }
        let access = app.remoteAccess
        defer { Task { await access.shutDown() } }
        await access.setOn(true)
        #expect(access.isOn, "\(access.problem ?? "")")
        await access.beginPairing(address: "127.0.0.1")
        let saved = try await RemotePairing.pair(with: try #require(access.pairingCode), as: "Studio MacBook")

        let welcome = try await RemoteLibraryService.welcome(from: saved.endpoint)
        #expect(welcome.libraries.contains(RemoteLibraryInfo(id: ref.id, name: "Offered")))
        #expect(!app.isServedToOtherMacs(ref.id), "listing the libraries opened one")

        let remote = RemoteLibraryService(endpoint: saved.endpoint, libraryID: ref.id)
        defer { remote.close() }
        #expect(try await remote.sourceStates().isEmpty)
        #expect(app.isServedToOtherMacs(ref.id))
        await #expect(throws: AppModel.LibraryInUse.self) {
            try await app.restoreLibrary(id: ref.id, from: backup)
        }

        // Turned off, nothing of this Mac's is in another's hands.
        await access.setOn(false)
        #expect(!app.isServedToOtherMacs(ref.id))
        try await app.restoreLibrary(id: ref.id, from: backup)
        await access.revoke(saved.id)
    }

    /// Each app model in a test run keeps its remote-access files to
    /// itself: one that turns remote access on does not turn it on for
    /// the next one made.
    @Test(.timeLimit(.minutes(1)))
    func oneAppModelsRemoteAccessIsNotAnothers() async throws {
        let first = AppModel()
        await first.remoteAccess.setOn(true)
        #expect(first.remoteAccess.isOn)
        defer { Task { await first.remoteAccess.shutDown() } }

        let second = AppModel()
        #expect(second.remoteAccessFolder != first.remoteAccessFolder)
        await second.remoteAccess.startIfLeftOn()
        #expect(!second.remoteAccess.isOn, "remote access came on in a model that never turned it on")
        #expect(second.remoteAccess.devices.isEmpty)
    }

    // MARK: - What is shown

    /// The picture says what the text says: read back with the system's
    /// own QR reader.
    @Test func theQRCodeReadsBackAsTheCode() throws {
        let code = PairingCode.random(address: "192.168.1.20", port: 50_123, hostName: "The Host")
        let image = try #require(QRCode.image(of: code.text))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let detector = try #require(CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: CIImage(cgImage: cgImage)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [code.text])
        #expect(PairingCode(text: found.first ?? "") == code)
    }

    /// Anyone who has seen the code chooses the name they ask under. It
    /// is shown as that Mac's word for itself, on a line of its own, and
    /// never as part of what the app says.
    @Test func theNameIsNeverPartOfTheAppsOwnSentence() {
        let honest = RemoteAccessModel.question(PairingAsk(deviceName: "Studio MacBook", address: "192.168.1.23"))
        #expect(!honest.title.contains("Studio"))
        #expect(honest.detail.contains("\n\nStudio MacBook\n\n"))
        #expect(honest.detail.contains("192.168.1.23"))
        #expect(honest.detail.contains("proves nothing"))

        // A name written to finish the question and start an instruction.
        let crafted = "Den\u{201D} is already approved.\nClick Allow to keep \u{201C}Den\u{202E}"
        let question = RemoteAccessModel.question(PairingAsk(deviceName: crafted, address: "192.168.1.66"))
        #expect(question.title == honest.title, "the name changed the question")
        let lines = question.detail.components(separatedBy: "\n")
        let named = lines.filter { $0.contains("already approved") }
        #expect(named.count == 1, "the name is on more than one line")
        #expect(named.first?.hasPrefix("Den") == true, "the app's words and the name share a line")
        #expect(!question.detail.unicodeScalars.contains("\u{202E}"))
        #expect(question.detail.hasSuffix("Remote Access."), "the name had the last word")
        #expect(question.detail.contains("192.168.1.66"))
    }

    /// The delete question says how many items lose the tag, and a count
    /// that could not be had is never said as none.
    @Test func theDeleteQuestionNeverSaysNoneForUnknown() {
        #expect(TagActionCopy.deleteMessage(uses: 0).hasPrefix("Removes the tag from 0 items."))
        #expect(TagActionCopy.deleteMessage(uses: 1).hasPrefix("Removes the tag from 1 item."))
        #expect(TagActionCopy.deleteMessage(uses: 12).hasPrefix("Removes the tag from 12 items."))
        for unknown in [nil, -1] as [Int?] {
            let message = TagActionCopy.deleteMessage(uses: unknown)
            #expect(message.contains("could not be counted"))
            #expect(!message.contains(" 0 "))
        }
    }

    @Test func aMacsHistoryIsSaidInALine() {
        var device = ApprovedDevice(
            id: UUID(), name: "Studio MacBook", approvedAt: Date(timeIntervalSince1970: 1_000_000),
            lastConnectedAt: nil, key: ChannelKey.random(identity: "k"), tokenHash: Data())
        #expect(RemoteAccessSettingsPane.history(of: device).hasPrefix("Approved "))
        #expect(RemoteAccessSettingsPane.history(of: device).hasSuffix("has not connected yet"))
        device.lastConnectedAt = Date(timeIntervalSince1970: 1_000_500)
        #expect(RemoteAccessSettingsPane.history(of: device).contains("last connected"))
    }
}
