import Foundation

/// One message on the channel: what kind it is, and its bytes. What the
/// kinds mean belongs to whoever is talking; the channel only carries
/// them.
public struct Frame: Equatable, Sendable {
    public var kind: UInt8
    public var payload: Data

    public init(kind: UInt8, payload: Data = Data()) {
        self.kind = kind
        self.payload = payload
    }
}

/// How a frame is told from the next on a stream of bytes: four bytes of
/// length, most significant first, then that many bytes — the kind, then
/// the payload.
public enum FrameCodec {
    /// The most a frame's payload may be. The length is read off the
    /// wire, so it is a number the other end chose: without a limit, four
    /// bytes could ask this end to wait for, and hold, four gigabytes.
    public static let maximumPayload = 64 << 20

    public static func encode(_ frame: Frame) throws -> Data {
        guard frame.payload.count <= maximumPayload else {
            throw ChannelError.frameTooLarge(frame.payload.count)
        }
        let length = UInt32(frame.payload.count + 1)
        var data = Data(capacity: frame.payload.count + 5)
        data.append(UInt8(truncatingIfNeeded: length >> 24))
        data.append(UInt8(truncatingIfNeeded: length >> 16))
        data.append(UInt8(truncatingIfNeeded: length >> 8))
        data.append(UInt8(truncatingIfNeeded: length))
        data.append(frame.kind)
        data.append(frame.payload)
        return data
    }

    /// Take one whole frame off the front of `buffer`, or nil when the
    /// buffer does not yet hold one. What is left stays for next time.
    public static func decode(from buffer: inout Data) throws -> Frame? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16
            | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
        guard length >= 1 else { throw ChannelError.malformed("a frame with no kind") }
        guard length - 1 <= maximumPayload else { throw ChannelError.frameTooLarge(length - 1) }
        guard buffer.count >= 4 + length else { return nil }
        let kind = buffer[start + 4]
        let payload = Data(buffer[(start + 5)..<(start + 4 + length)])
        buffer = Data(buffer[(start + 4 + length)...])
        return Frame(kind: kind, payload: payload)
    }
}

public enum ChannelError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The other end would not complete the connection: nothing is
    /// listening, the key is not one it holds, or it does not take this
    /// address.
    case refused(String)
    /// The connection was made on a suite other than the one asked for.
    case weakSuite(UInt16?)
    case timedOut
    /// The other end went away.
    case closed
    case broken(String)
    case frameTooLarge(Int)
    case malformed(String)

    public var description: String {
        switch self {
        case .refused(let why): "the other Mac did not accept the connection (\(why))"
        case .weakSuite: "the connection was not encrypted the way it has to be, and was dropped"
        case .timedOut: "the other Mac did not answer in time"
        case .closed: "the other Mac closed the connection"
        case .broken(let why): "the connection failed (\(why))"
        case .frameTooLarge(let size): "a message of \(size) bytes is more than the channel carries"
        case .malformed(let what): "the other Mac sent something that could not be read (\(what))"
        }
    }
}
