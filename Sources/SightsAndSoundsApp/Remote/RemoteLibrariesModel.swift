import CryptoKit
import Foundation
import SightsAndSoundsKit
import SightsAndSoundsRemote
import SwiftUI

/// A library another Mac holds, as this Mac's windows know it.
struct RemoteLibraryRef: Identifiable, Equatable, Sendable {
    /// What its window — and everything in this app that is kept "by
    /// library" — calls it. Not the library's own id on its host: see
    /// `windowID(hostID:libraryID:)`.
    let id: UUID
    let host: SavedHost
    let library: RemoteLibraryInfo

    init(host: SavedHost, library: RemoteLibraryInfo) {
        id = Self.windowID(hostID: host.id, libraryID: library.id)
        self.host = host
        self.library = library
    }

    /// The id this Mac knows a remote library by: made from the host and
    /// the library together, the same every time.
    ///
    /// The library's own id will not do. A library copied to two Macs, or
    /// a Mac connected to itself, has one id in two places, and this
    /// app's windows, thumbnails and saved state are all kept by id: the
    /// remote one would be taken for the local. With an id of its own,
    /// anything that goes looking for a database under it finds none,
    /// which is the truth.
    static func windowID(hostID: UUID, libraryID: UUID) -> UUID {
        var hasher = SHA256()
        withUnsafeBytes(of: hostID.uuid) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: libraryID.uuid) { hasher.update(bufferPointer: $0) }
        let digest = Array(hasher.finalize().prefix(16))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}

/// The other Macs this one can connect to, and their libraries: what the
/// library picker lists under "On Other Macs", and where a window on one
/// of them gets its service.
@Observable @MainActor
final class RemoteLibrariesModel {
    struct HostEntry: Identifiable, Equatable {
        enum State: Equatable {
            /// Being asked which libraries it has.
            case asking
            case reachable
            /// Not answering. Why, in words.
            case unreachable(String)
            /// It answered, and would not have this Mac: revoked there,
            /// or a different version of the app.
            case refused(String)
        }

        var host: SavedHost
        var state: State
        /// As last heard, so there is something to show while it is
        /// asked again, or cannot be reached.
        var libraries: [RemoteLibraryRef]
        var id: UUID { host.id }
    }

    struct NotACode: Error, CustomStringConvertible {
        var description: String {
            "That is not a pairing code. Copy the whole code from the other Mac: it begins SAS-PAIR-."
        }
    }

    private(set) var hosts: [HostEntry] = []
    /// Why the saved Macs could not be read, or the last change kept.
    private(set) var problem: String?

    private let store: HostStore?
    /// One service for each remote library with a window open.
    private var services: [UUID: RemoteLibraryService] = [:]
    /// How many windows are on each: the library's own, and any player
    /// opened beside it.
    private var windows: [UUID: Int] = [:]

    init(file: URL) {
        do {
            store = try HostStore(file: file)
        } catch {
            store = nil
            problem = "The Macs this one has been paired with could not be read. Nothing has been changed. (\(error))"
        }
        reload()
    }

    /// False when the saved Macs could not be read: nothing is paired
    /// over a list that might be written over.
    var isAvailable: Bool { store != nil }

    private func reload() {
        guard let store else { return }
        let before = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0.state) })
        hosts = store.hosts.map { host in
            HostEntry(
                host: host, state: before[host.id] ?? .asking,
                libraries: (host.knownLibraries ?? []).map { RemoteLibraryRef(host: host, library: $0) })
        }
    }

    // MARK: - Asking the hosts

    /// Ask every saved Mac which libraries it has, all at once. Each
    /// row says how its own asking went; one that is off does not hold
    /// up the others.
    func refresh() async {
        guard let store else { return }
        let asked = store.hosts
        await withTaskGroup(of: (UUID, Result<Welcome, RemoteError>).self) { group in
            for host in asked {
                group.addTask {
                    do {
                        return (host.id, .success(
                            try await RemoteLibraryService.welcome(from: host.endpoint, timeout: .seconds(5))))
                    } catch let error as RemoteError {
                        return (host.id, .failure(error))
                    } catch {
                        return (host.id, .failure(.unreachable("\(error)")))
                    }
                }
            }
            for await (id, answer) in group {
                switch answer {
                case .success(let welcome):
                    try? store.heard(from: id, name: welcome.hostName, libraries: welcome.libraries)
                    reload()
                    set(.reachable, for: id)
                case .failure(.refused(let refusal)):
                    set(.refused(refusal.message), for: id)
                case .failure(let error):
                    set(.unreachable("\(error)"), for: id)
                }
            }
        }
    }

    private func set(_ state: HostEntry.State, for id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].state = state
    }

    // MARK: - Pairing and forgetting

    /// Ask the Mac a pairing code came from to let this one in. Returns
    /// when whoever is at that Mac has answered.
    @discardableResult
    func pair(codeText: String, as deviceName: String) async throws -> SavedHost {
        guard let store else { throw RemoteHostError.notRunning }
        guard let code = PairingCode(text: codeText) else { throw NotACode() }
        let saved = try await RemotePairing.pair(with: code, as: deviceName)
        try store.save(saved)
        reload()
        await refresh()
        return saved
    }

    /// Forget a Mac: its way in is thrown away here. That Mac still
    /// lists this one until it is revoked there.
    func forget(_ hostID: UUID) {
        guard let store else { return }
        do {
            try store.remove(hostID)
            for (id, service) in services where ref(for: id)?.host.id == hostID || ref(for: id) == nil {
                service.close()
                services[id] = nil
            }
            problem = nil
        } catch {
            problem = "That Mac could not be forgotten: \(error)"
        }
        reload()
    }

    /// The Mac has a new address or port.
    func move(_ hostID: UUID, toAddress address: String, port: UInt16) async {
        guard let store else { return }
        do {
            try store.move(hostID, toAddress: address, port: port)
            problem = nil
        } catch {
            problem = "The new address could not be kept: \(error)"
        }
        reload()
        await refresh()
    }

    // MARK: - Windows

    /// The remote library a window id stands for, if it stands for one.
    func ref(for windowID: UUID) -> RemoteLibraryRef? {
        for entry in hosts {
            if let found = entry.libraries.first(where: { $0.id == windowID }) { return found }
        }
        return nil
    }

    /// The service for a remote library's window: one for as long as
    /// the window is open, shared by everything in it.
    func service(for windowID: UUID) -> RemoteLibraryService? {
        if let open = services[windowID] { return open }
        guard let ref = ref(for: windowID) else { return nil }
        let service = RemoteLibraryService(endpoint: ref.host.endpoint, libraryID: ref.library.id)
        services[windowID] = service
        return service
    }

    /// The remote libraries something here has a service for — a window
    /// open on them — by name. Nothing is connected to in order to say.
    var openLibraries: [(ref: RemoteLibraryRef, service: RemoteLibraryService)] {
        services
            .compactMap { id, service in ref(for: id).map { (ref: $0, service: service) } }
            .sorted { $0.ref.library.name.localizedStandardCompare($1.ref.library.name) == .orderedAscending }
    }

    /// A window on the library has opened.
    func windowOpened(_ windowID: UUID) {
        guard ref(for: windowID) != nil else { return }
        windows[windowID, default: 0] += 1
    }

    /// A window on the library has closed. When it was the last, the
    /// host is let go of.
    func windowClosed(_ windowID: UUID) {
        guard let open = windows[windowID] else { return }
        windows[windowID] = open > 1 ? open - 1 : nil
        if open <= 1 { closeService(for: windowID) }
    }

    /// Let go of the host, whoever is still using it.
    func closeService(for windowID: UUID) {
        services[windowID]?.close()
        services[windowID] = nil
        windows[windowID] = nil
    }
}

// MARK: - What a view can know about its library

private struct LibraryIsRemoteKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a window on a library another Mac holds. The parts of
    /// the app that still work on a database, not through the library's
    /// service, read it and stand aside.
    var libraryIsRemote: Bool {
        get { self[LibraryIsRemoteKey.self] }
        set { self[LibraryIsRemoteKey.self] = newValue }
    }
}

/// What stands where a surface would be that has not yet been moved onto
/// the library's service, in a window on a library another Mac holds.
struct NotAvailableRemotelyView: View {
    static let line = "Not available for a remote library yet"
    let what: String

    var body: some View {
        ContentUnavailableView(
            Self.line,
            systemImage: "network.slash",
            description: Text("\(what) still works only on a library held by this Mac. Use it on the Mac that holds this library."))
            .frame(minWidth: 420, minHeight: 240)
    }
}

extension View {
    /// Disable a control in a window on a remote library, and say why.
    /// What is left behind this is not waiting to be built: it acts on
    /// the other Mac's own disk — a folder to add, a file to show in its
    /// Finder — and is done there.
    @ViewBuilder
    func unavailableRemotely(_ isRemote: Bool) -> some View {
        if isRemote {
            self.disabled(true).help("Done on the Mac that holds this library")
        } else {
            self
        }
    }
}
