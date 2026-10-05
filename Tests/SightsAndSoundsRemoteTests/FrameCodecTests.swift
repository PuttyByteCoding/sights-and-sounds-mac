import Foundation
import Testing

@testable import SightsAndSoundsRemote

/// A frame is how one message is told from the next on a stream of bytes:
/// its length, its kind, its bytes.
@Suite struct FrameCodecTests {
    @Test func aFrameSurvivesEncodingAndDecoding() throws {
        for frame in [
            Frame(kind: 4, payload: Data("hello".utf8)),
            Frame(kind: 9, payload: Data()),
            Frame(kind: 255, payload: Data((0..<70_000).map { UInt8($0 % 251) })),
        ] {
            var buffer = try FrameCodec.encode(frame)
            #expect(try FrameCodec.decode(from: &buffer) == frame)
            #expect(buffer.isEmpty)
        }
    }

    @Test func framesComeOffTheFrontOneAtATimeAndAPartOfOneWaits() throws {
        let first = Frame(kind: 1, payload: Data("one".utf8))
        let second = Frame(kind: 2, payload: Data("two!".utf8))
        let all = try FrameCodec.encode(first) + FrameCodec.encode(second)

        // Fed a byte at a time, as a network may.
        var buffer = Data()
        var decoded: [Frame] = []
        for byte in all {
            buffer.append(byte)
            while let frame = try FrameCodec.decode(from: &buffer) { decoded.append(frame) }
        }
        #expect(decoded == [first, second])
        #expect(buffer.isEmpty)
    }

    /// The length comes from the other end. One that claims more than a
    /// frame may hold is refused before anything is waited for.
    @Test func aLengthPastTheLimitIsRefused() throws {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x04])
        #expect(throws: ChannelError.self) { _ = try FrameCodec.decode(from: &buffer) }
        let tooBig = Frame(kind: 4, payload: Data(count: FrameCodec.maximumPayload + 1))
        #expect(throws: ChannelError.self) { _ = try FrameCodec.encode(tooBig) }
        // Exactly the limit is a frame.
        #expect(try FrameCodec.encode(Frame(kind: 4, payload: Data(count: 1024))).count == 1024 + 5)
    }

    @Test func aLengthOfNothingIsRefused() throws {
        // A frame is at least its kind.
        var buffer = Data([0, 0, 0, 0])
        #expect(throws: ChannelError.self) { _ = try FrameCodec.decode(from: &buffer) }
    }
}
