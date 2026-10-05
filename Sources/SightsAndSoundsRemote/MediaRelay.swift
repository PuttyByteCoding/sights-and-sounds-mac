import Foundation
import Network
import UniformTypeIdentifiers

/// What a player on this Mac plays a remote item from.
///
/// A player wants a URL it can open and seek in. The item's file is on
/// another Mac, behind a channel only this app speaks. So this listens on
/// this Mac's own loopback, answers the player in plain HTTP — the one
/// place HTTP is spoken — and fetches each range it is asked for through
/// the channel.
///
/// It is reachable only from this Mac, and a URL of it carries a random
/// token: another program here cannot read a video by knowing, or
/// guessing, an item's id.
public final class MediaRelay: @unchecked Sendable {
    /// Some of an item's file, from the host.
    public typealias Read = @Sendable (_ itemID: UUID, _ offset: Int64, _ length: Int) async throws -> MediaBytes

    private let read: Read
    private let token: String
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var starting: Task<UInt16, any Error>?
    private var stopped = false
    private var open: [ObjectIdentifier: NWConnection] = [:]

    private static let queue = DispatchQueue(label: "sas.remote.relay", attributes: .concurrent)
    /// How much is fetched from the host at a time. A player often asks
    /// for the rest of the file and then goes away having read a little:
    /// small enough that little is wasted, large enough to keep up.
    static let chunk = 512 << 10
    private static let longestRequest = 32 << 10

    public init(read: @escaping Read) {
        self.read = read
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "the system could not supply random bytes")
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Where a player opens an item. Starts listening the first time it
    /// is asked. The extension is the file's own, so a player that goes
    /// by the name as well as the type is told the same thing twice.
    public func url(for itemID: UUID, fileExtension: String) async throws -> URL {
        let port = try await start()
        let suffix = fileExtension.isEmpty || !fileExtension.allSatisfy({ $0.isLetter || $0.isNumber })
            ? "" : ".\(fileExtension.lowercased())"
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/\(itemID.uuidString)\(suffix)") else {
            throw ChannelError.malformed("a relay address")
        }
        return url
    }

    @discardableResult
    func start() async throws -> UInt16 {
        let attempt = lock.withLock { () -> Result<Task<UInt16, any Error>, any Error> in
            if stopped { return .failure(ChannelError.closed) }
            if let starting { return .success(starting) }
            let task = Task { try await self.listen() }
            starting = task
            return .success(task)
        }
        let task = try attempt.get()
        do {
            return try await task.value
        } catch {
            // Not left as the answer for ever after: the next player to
            // ask tries again.
            lock.withLock { if starting == task { starting = nil } }
            throw error
        }
    }

    private func listen() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        // This Mac only: the loopback interface, and no caller from
        // anywhere else even if one could arrive there.
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, Self.isThisMac(connection.endpoint) else {
                connection.cancel()
                return
            }
            Task { await self.serve(connection) }
        }
        let ready = OneShot<UInt16>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.succeed(listener.port?.rawValue ?? 0)
            case .failed(let error): ready.fail(ChannelError.refused("\(error)"))
            case .cancelled: ready.fail(ChannelError.closed)
            default: break
            }
        }
        listener.start(queue: Self.queue)
        do {
            let port = try await ready.value
            let late = lock.withLock { () -> Bool in
                guard !stopped else { return true }
                self.listener = listener
                self.port = port
                return false
            }
            if late {
                listener.cancel()
                throw ChannelError.closed
            }
            return port
        } catch {
            listener.cancel()
            throw error
        }
    }

    /// Stop, for good: nothing listens, and what was being played from
    /// here stops arriving.
    public func stop() {
        let (listener, connections) = lock.withLock { () -> (NWListener?, [NWConnection]) in
            stopped = true
            let listener = self.listener
            self.listener = nil
            let connections = Array(open.values)
            open = [:]
            return (listener, connections)
        }
        listener?.cancel()
        for connection in connections { connection.cancel() }
    }

    private static func isThisMac(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }

    // MARK: - One connection

    private func serve(_ connection: NWConnection) async {
        let known = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            open[ObjectIdentifier(connection)] = connection
            return true
        }
        defer {
            lock.withLock { open[ObjectIdentifier(connection)] = nil }
            connection.cancel()
        }
        guard known else { return }
        let ready = OneShot<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.succeed(())
            case .failed, .cancelled, .waiting: ready.fail(ChannelError.closed)
            default: break
            }
        }
        connection.start(queue: Self.queue)
        guard (try? await ready.value) != nil else { return }

        var buffer = Data()
        // A player asks for one range after another on the connection it
        // has, for as long as it keeps it.
        while let request = await Self.request(from: connection, buffer: &buffer) {
            guard await respond(to: request, on: connection) else { return }
        }
    }

    struct Request: Equatable {
        var method: String
        var path: String
        var range: String?
        var closes: Bool
    }

    /// The next request's head, or nil when the caller has gone, or sent
    /// something that is not one.
    private static func request(from connection: NWConnection, buffer: inout Data) async -> Request? {
        let end = Data("\r\n\r\n".utf8)
        while true {
            if let found = buffer.range(of: end) {
                let head = Data(buffer[buffer.startIndex..<found.lowerBound])
                buffer = Data(buffer[found.upperBound...])
                return parse(head)
            }
            guard buffer.count < longestRequest, let more = await receive(from: connection) else { return nil }
            buffer.append(more)
        }
    }

    static func parse(_ head: Data) -> Request? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return nil }
        var request = Request(method: String(first[0]), path: String(first[1]), range: nil, closes: false)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "range" { request.range = value }
            if name == "connection", value.lowercased() == "close" { request.closes = true }
        }
        return request
    }

    private static func receive(from connection: NWConnection) async -> Data? {
        let chunk = OneShot<Data>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) { data, _, _, error in
            if let data, !data.isEmpty {
                chunk.succeed(data)
            } else {
                chunk.fail(error ?? ChannelError.closed)
            }
        }
        return try? await chunk.value
    }

    private static func send(_ data: Data, on connection: NWConnection) async -> Bool {
        let sent = OneShot<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { sent.fail(error) } else { sent.succeed(()) }
        })
        return (try? await sent.value) != nil
    }

    // MARK: - One request

    /// Which bytes of a file of `total` a Range header asks for. Nil
    /// header, or one this does not read, is the whole file; `.none` in
    /// the result is a range the file does not have.
    enum Span: Equatable {
        case whole
        case part(ClosedRange<Int64>)
        case unsatisfiable
    }

    static func span(of header: String?, total: Int64) -> Span {
        guard let header, header.lowercased().hasPrefix("bytes="), !header.contains(",") else { return .whole }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard let dash = spec.firstIndex(of: "-") else { return .whole }
        let first = String(spec[..<dash]), last = String(spec[spec.index(after: dash)...])
        if first.isEmpty {
            // The last so many bytes.
            guard let count = Int64(last), count > 0 else { return .unsatisfiable }
            guard total > 0 else { return .unsatisfiable }
            return .part(max(0, total - count)...(total - 1))
        }
        guard let start = Int64(first), start >= 0 else { return .whole }
        guard start < total else { return .unsatisfiable }
        guard !last.isEmpty else { return .part(start...(total - 1)) }
        guard let end = Int64(last), end >= start else { return .whole }
        return .part(start...min(end, total - 1))
    }

    /// The item a path names, when it carries this relay's token.
    func item(at path: String) -> (id: UUID, type: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, String(parts[0]) == token else { return nil }
        let name = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
        let pieces = name.split(separator: ".", maxSplits: 1)
        guard let first = pieces.first, let id = UUID(uuidString: String(first)) else { return nil }
        let fileExtension = pieces.count > 1 ? String(pieces[1]) : ""
        let type = UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
        return (id, type)
    }

    /// Answer one request. False when the connection is of no more use.
    private func respond(to request: Request, on connection: NWConnection) async -> Bool {
        func plain(_ status: String, _ extra: String = "") async -> Bool {
            let head = "HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\n\r\n"
            return await Self.send(Data(head.utf8), on: connection) && !request.closes
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            return await plain("405 Method Not Allowed", "Allow: GET, HEAD\r\n")
        }
        guard let item = item(at: request.path) else { return await plain("404 Not Found") }

        // How long the file is comes with the first bytes of it. Where
        // the range does not say where to start — the last so many
        // bytes, or a question about the file alone — it is asked for
        // by itself.
        var first: MediaBytes
        var firstOffset: Int64 = 0
        do {
            if request.method == "GET", let header = request.range,
               case .part(let range) = Self.span(of: header, total: .max),
               !header.dropFirst("bytes=".count).hasPrefix("-") {
                firstOffset = range.lowerBound
                let wanted = min(Int64(Self.chunk), range.upperBound - range.lowerBound + 1)
                first = try await read(item.id, firstOffset, Int(wanted))
            } else {
                first = try await read(item.id, 0, 0)
            }
        } catch {
            return await plain("502 Bad Gateway")
        }
        let total = first.total

        let wanted: ClosedRange<Int64>?
        var head: String
        switch Self.span(of: request.range, total: total) {
        case .unsatisfiable:
            return await plain("416 Range Not Satisfiable", "Content-Range: bytes */\(total)\r\n")
        case .whole:
            wanted = total > 0 ? 0...(total - 1) : nil
            head = "HTTP/1.1 200 OK\r\n"
        case .part(let range):
            wanted = range
            head = "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(total)\r\n"
        }
        let length = wanted.map { $0.upperBound - $0.lowerBound + 1 } ?? 0
        head += "Content-Type: \(item.type)\r\nAccept-Ranges: bytes\r\nContent-Length: \(length)\r\n\r\n"
        guard await Self.send(Data(head.utf8), on: connection) else { return false }
        guard request.method == "GET", let wanted else { return !request.closes }

        var offset = wanted.lowerBound
        var ready = offset == firstOffset && !first.data.isEmpty ? first.data : nil
        while offset <= wanted.upperBound {
            let remaining = wanted.upperBound - offset + 1
            var piece: Data
            if let have = ready {
                piece = have
                ready = nil
            } else {
                // Once the head has gone there is no status left to
                // change: a file that stops coming ends the connection,
                // and the player sees it cut short.
                guard let more = try? await read(item.id, offset, Int(min(Int64(Self.chunk), remaining))),
                      !more.data.isEmpty
                else { return false }
                piece = more.data
            }
            if Int64(piece.count) > remaining { piece = piece.prefix(Int(remaining)) }
            guard await Self.send(piece, on: connection) else { return false }
            offset += Int64(piece.count)
        }
        return !request.closes
    }
}
