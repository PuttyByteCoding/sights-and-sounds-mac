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

/// Why a host would not have a connection.
public struct Refusal: Codable, Equatable, Sendable, Error, CustomStringConvertible {
    public enum Reason: String, Codable, Sendable {
        /// Not a device this host has approved, or one it has revoked.
        case notApproved
        /// The two Macs are not running builds that can talk to each
        /// other.
        case versionMismatch
        case noSuchLibrary
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
