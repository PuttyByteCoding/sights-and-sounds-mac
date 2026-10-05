import AppKit
import Foundation
import SightsAndSoundsKit
import SightsAndSoundsRemote

/// This Mac's libraries, offered to the Macs it has approved: what the
/// Remote Access pane in Settings shows and changes.
///
/// It decides nothing about who is let in. That is the `RemoteHost`'s,
/// and behind it a question put to whoever is at this Mac.
@Observable @MainActor
final class RemoteAccessModel {
    /// What this Mac has to offer, asked each time a Mac connects.
    struct Offer {
        var hostName: @Sendable () -> String
        var libraries: @MainActor () -> [RemoteLibraryInfo]
        var service: @MainActor (UUID) -> (any LibraryService)?
        /// Remote access has been turned off: nothing offered is in use.
        var turnedOff: @MainActor () -> Void
    }

    private(set) var isOn = false
    /// Being turned on or off; the switch waits.
    private(set) var isChanging = false
    private(set) var port: UInt16?
    private(set) var devices: [ApprovedDevice] = []
    /// The code on offer, while one is.
    private(set) var pairingCode: PairingCode?
    /// Why remote access is off when it was meant to be on, or could not
    /// do what was asked.
    private(set) var problem: String?
    /// The port it used last is taken by something else. Another can be
    /// chosen, and then every paired Mac has to be told.
    private(set) var portIsTaken = false

    /// False when the list of approved Macs could not be read. Nothing
    /// is turned on over a list that might be written over.
    var isAvailable: Bool { host != nil }

    private let store: DeviceStore?
    private let host: RemoteHost?
    private let offer: Offer
    private var watching: Task<Void, Never>?

    /// - Parameters:
    ///   - file: where the approved Macs are kept.
    ///   - ask: puts the question to whoever is at this Mac. An alert,
    ///     unless a test answers instead.
    init(
        file: URL, offer: Offer,
        ask: @escaping @MainActor (PairingAsk) async -> Bool = RemoteAccessModel.askWithAnAlert
    ) {
        self.offer = offer
        do {
            let store = try DeviceStore(file: file)
            self.store = store
            host = RemoteHost(
                store: store,
                hostName: offer.hostName,
                libraries: { await MainActor.run { offer.libraries() } },
                service: { id in await MainActor.run { offer.service(id) } },
                approve: { question in await ask(question) })
            devices = store.devices
        } catch {
            store = nil
            host = nil
            problem = "The list of approved Macs could not be read, so remote access is off. Nothing in it has been changed. (\(error))"
        }
        if let host {
            watching = Task { [weak self] in
                for await _ in host.changes() {
                    await self?.refresh()
                }
            }
        }
    }

    /// The addresses another Mac on the local network could reach this
    /// one at.
    var addresses: [String] { RemoteAddress.ofThisMac() }

    // MARK: - On and off

    /// At launch: on again if it was left on.
    func startIfLeftOn() async {
        guard let store, store.isEnabled else { return }
        await turnOn(onANewPort: false)
    }

    func setOn(_ on: Bool) async {
        guard let host, let store, !isChanging else { return }
        if on {
            await turnOn(onANewPort: false)
        } else {
            isChanging = true
            await host.stop()
            // Remembered even if it cannot be written: it is off now.
            try? store.setEnabled(false)
            offer.turnedOff()
            isChanging = false
            problem = nil
            portIsTaken = false
            await refresh()
        }
    }

    /// The app is going away: stop listening, and leave whether it was
    /// on as it is, to be on again next time.
    func shutDown() async {
        await host?.stop()
        await refresh()
    }

    /// Listen on a port of the system's choosing, in place of the one
    /// used until now.
    func useAnotherPort() async {
        await turnOn(onANewPort: true)
    }

    private func turnOn(onANewPort: Bool) async {
        guard let host, let store, !isChanging else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            try await host.start(onANewPort: onANewPort)
            try store.setEnabled(true)
            problem = nil
            portIsTaken = false
        } catch {
            // A port kept from last time and now in use by something
            // else is the one failure with a way out.
            portIsTaken = store.port != nil
            problem = portIsTaken
                ? "Port \(store.port ?? 0), which this Mac used for remote access last time, is in use by something else."
                : "Remote access could not be turned on: \(error)"
        }
        await refresh()
    }

    // MARK: - Pairing and devices

    func beginPairing(address: String) async {
        guard let host else { return }
        do {
            _ = try await host.beginPairing(address: address)
            problem = nil
        } catch {
            problem = "A pairing code could not be made: \(error)"
        }
        await refresh()
    }

    func endPairing() async {
        await host?.endPairing()
        await refresh()
    }

    func revoke(_ id: UUID) async {
        guard let host else { return }
        do {
            try await host.revoke(id)
        } catch {
            problem = "That Mac could not be revoked: \(error)"
        }
        await refresh()
    }

    /// Bring what is shown into line with the host.
    func refresh() async {
        guard let host, let store else { return }
        isOn = await host.isRunning
        port = await host.port
        pairingCode = await host.pairingCode
        devices = store.devices
        if let failure = await host.failure { problem = failure }
    }

    // MARK: - The question

    /// What whoever is at this Mac is asked.
    ///
    /// The name is the other Mac's own word for itself: anyone who has
    /// seen the pairing code can ask under any name. So it is never part
    /// of a sentence of the app's. It stands on a line of its own, said
    /// to be what that Mac calls itself, between what the app knows for
    /// itself — the address — and what allowing it means. A name written
    /// to read as an instruction, or as the end of the question, has
    /// nothing of the app's voice to borrow.
    static func question(_ ask: PairingAsk) -> (title: String, detail: String) {
        (
            "Let another Mac use this Mac\u{2019}s libraries?",
            """
            A Mac at \(ask.address) is asking, with the pairing code just made here. \
            It gives its name as:

            \(DeviceStore.presentable(ask.deviceName))

            That name is the other Mac\u{2019}s own word for itself and proves nothing. Allow only if \
            you are pairing a Mac right now and this is the one. It will be able to browse, play, tag \
            and manage every library on this Mac until it is revoked in Settings \u{25B8} Remote Access.
            """
        )
    }

    /// Ask whoever is at this Mac. The default answer, for a Return
    /// pressed without reading, is no.
    static func askWithAnAlert(_ ask: PairingAsk) async -> Bool {
        let question = question(ask)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.detail
        alert.addButton(withTitle: "Don\u{2019}t Allow")
        alert.addButton(withTitle: "Allow")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
