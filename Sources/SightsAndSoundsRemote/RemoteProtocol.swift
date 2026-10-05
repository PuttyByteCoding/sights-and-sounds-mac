import Foundation
import SightsAndSoundsKit

/// What the two ends say to each other on the channel.
///
/// Every connection begins with a `Hello` and is answered with a
/// `Welcome` or a `Refusal`. After a welcome it carries requests, one at
/// a time, each answered before the next; or it is given over to the
/// library's change stream.
public enum RemoteProtocol {
    /// Raised whenever the frames or what is in them change shape.
    public static let version = 1

    public enum Kind {
        public static let hello: UInt8 = 1
        public static let welcome: UInt8 = 2
        public static let refusal: UInt8 = 3
        public static let request: UInt8 = 4
        /// The answer, as JSON.
        public static let answer: UInt8 = 5
        /// The answer, as JSON compressed with zlib.
        public static let compressedAnswer: UInt8 = 6
        /// The request could not be carried out; the reason, as text.
        public static let failure: UInt8 = 7
        /// Give this connection over to the change stream.
        public static let subscribe: UInt8 = 8
        public static let change: UInt8 = 9
        public static let ping: UInt8 = 10
        public static let pong: UInt8 = 11
        /// A Mac that is not yet approved asks to be: sent first, in
        /// place of a hello, on a connection made with a pairing code.
        public static let pair: UInt8 = 12
        /// The host's yes: the device's own key and token.
        public static let grant: UInt8 = 13
        /// Some of an item's file: which item, from where, how much.
        public static let media: UInt8 = 14
        /// The answer to `media`: the size of the whole file, then the
        /// bytes asked for. Not JSON — these are the video itself.
        public static let bytes: UInt8 = 15
    }

    /// An answer this large or larger is compressed. A listing of a big
    /// library is the same few keys many thousand times over.
    static let compressionThreshold = 32 << 10

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ChannelError.malformed("\(type): \(error)")
        }
    }

    /// An answer as a frame, compressed when that is worth it.
    static func answerFrame(_ json: Data) -> Frame {
        if json.count >= compressionThreshold,
           let packed = try? (json as NSData).compressed(using: .zlib) as Data, packed.count < json.count {
            return Frame(kind: Kind.compressedAnswer, payload: packed)
        }
        return Frame(kind: Kind.answer, payload: json)
    }

    /// The JSON of an answer frame.
    static func answerJSON(_ frame: Frame) throws -> Data {
        switch frame.kind {
        case Kind.answer:
            return frame.payload
        case Kind.compressedAnswer:
            guard let json = try? (frame.payload as NSData).decompressed(using: .zlib) as Data else {
                throw ChannelError.malformed("a compressed answer that would not open")
            }
            return json
        default:
            throw ChannelError.malformed("a frame of kind \(frame.kind) where an answer was expected")
        }
    }
}

/// Who is calling, said first on every connection.
public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// The library schema the caller was built for.
    public var schema: String
    public var deviceID: UUID
    public var token: Data
    /// The library the connection is for; nil to be told which there are.
    public var libraryID: UUID?

    public init(
        protocolVersion: Int = RemoteProtocol.version, schema: String = LibraryDatabase.schemaIdentifier,
        deviceID: UUID, token: Data, libraryID: UUID?
    ) {
        self.protocolVersion = protocolVersion
        self.schema = schema
        self.deviceID = deviceID
        self.token = token
        self.libraryID = libraryID
    }
}

public struct Welcome: Codable, Equatable, Sendable {
    public var hostName: String
    public var libraries: [RemoteLibraryInfo]

    public init(hostName: String, libraries: [RemoteLibraryInfo]) {
        self.hostName = hostName
        self.libraries = libraries
    }
}

/// A library a host offers.
public struct RemoteLibraryInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// A piece of an item's file, asked for by the item's id. Never by
/// path: which file an item is, is the host's library's to say.
public struct MediaRead: Codable, Equatable, Sendable {
    public var itemID: UUID
    public var offset: Int64
    public var length: Int

    /// The most that comes back in one answer, whatever was asked for.
    public static let maximumLength = 1 << 20

    public init(itemID: UUID, offset: Int64, length: Int) {
        self.itemID = itemID
        self.offset = offset
        self.length = length
    }
}

/// The answer to a `MediaRead`.
public struct MediaBytes: Equatable, Sendable {
    /// How long the whole file is.
    public var total: Int64
    /// From the offset asked for: as much as was asked, or as the host
    /// sends at once, or as the file has left. Empty at its end.
    public var data: Data

    public init(total: Int64, data: Data) {
        self.total = total
        self.data = data
    }

    var frame: Frame {
        var payload = Data(capacity: data.count + 8)
        for shift in stride(from: 56, through: 0, by: -8) {
            payload.append(UInt8(truncatingIfNeeded: total >> Int64(shift)))
        }
        payload.append(data)
        return Frame(kind: RemoteProtocol.Kind.bytes, payload: payload)
    }

    init(frame: Frame) throws {
        guard frame.kind == RemoteProtocol.Kind.bytes, frame.payload.count >= 8 else {
            throw ChannelError.malformed("a frame of kind \(frame.kind) where a file's bytes were expected")
        }
        var total: Int64 = 0
        for byte in frame.payload.prefix(8) { total = total << 8 | Int64(byte) }
        guard total >= 0 else { throw ChannelError.malformed("a file of less than no length") }
        self.total = total
        self.data = Data(frame.payload.dropFirst(8))
    }
}

/// A Mac asking to be approved.
public struct PairRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// What the device calls itself; what the host's user is shown.
    public var deviceName: String
    /// That the device holds the pairing code's secret.
    public var proof: Data

    public init(protocolVersion: Int = RemoteProtocol.version, deviceName: String, proof: Data) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.proof = proof
    }
}

/// The host's yes to a `PairRequest`: who the device is from now on.
public struct PairGrant: Codable, Equatable, Sendable {
    public var hostName: String
    public var deviceID: UUID
    public var key: ChannelKey
    public var token: Data
}

/// Why a host would not have a connection.
public struct Refusal: Codable, Equatable, Sendable, Error, CustomStringConvertible {
    public enum Reason: String, Codable, Sendable {
        /// Not a device this host has approved, or one it has revoked.
        case notApproved
        /// The two Macs are not running builds that can talk to each
        /// other.
        case versionMismatch
        case noSuchLibrary
        /// Asked to pair, and the host's user said no; or the host is
        /// not pairing a device just now.
        case notPaired
    }

    public var reason: Reason
    public var message: String

    public init(_ reason: Reason, _ message: String) {
        self.reason = reason
        self.message = message
    }

    public var description: String { message }
}

/// What went wrong with a request, as the client meets it.
public enum RemoteError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The host would not have the connection.
    case refused(Refusal)
    /// The host tried, and it failed there: its own words for why.
    case failed(String)
    /// The host could not be reached, or stopped answering.
    case unreachable(String)

    public var description: String {
        switch self {
        case .refused(let refusal): refusal.message
        case .failed(let message): message
        case .unreachable(let why): "The other Mac could not be reached: \(why)"
        }
    }
}
