import Foundation
import Testing

@testable import SightsAndSoundsKit

/// The tag-write remux fallback rewrites the whole file. Its scratch copy
/// must sit on the file's own volume: in the system temp folder, a
/// library on an external drive needed the whole video's size free on
/// the boot disk, and the swap back became a cross-volume copy.
@Suite(.serialized) struct TagRemuxScratchTests {
    /// A small disk image, attached for the test — the only way to have
    /// a second volume on any machine. Nil where images cannot attach.
    private final class Volume {
        let mountPoint: URL
        private let image: URL

        init?() {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("tag-remux-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            image = base.appendingPathComponent("volume.dmg")
            guard Self.run(["create", "-size", "16m", "-fs", "HFS+", "-volname", "SASTagRemux", image.path, "-quiet"]),
                  let mount = Self.attach(image, under: base)
            else { return nil }
            mountPoint = mount
        }

        deinit {
            _ = Self.run(["detach", mountPoint.path, "-quiet", "-force"])
            try? FileManager.default.removeItem(at: image.deletingLastPathComponent())
        }

        private static func attach(_ image: URL, under base: URL) -> URL? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["attach", image.path, "-nobrowse", "-mountrandom", base.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard let line = text.split(separator: "\n").last(where: { $0.contains(base.path) }),
                  let range = line.range(of: base.path)
            else { return nil }
            return URL(fileURLWithPath: String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces))
        }

        @discardableResult
        private static func run(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }

    private func volumeID(_ url: URL) throws -> NSObject? {
        try url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
    }

    @Test func theScratchCopyIsOnTheFilesOwnVolume() throws {
        guard let volume = Volume() else { return }  // no disk images here
        let file = volume.mountPoint.appendingPathComponent("show.mp4")
        try Data("media".utf8).write(to: file)

        let scratch = try TagWriters.remuxScratchURL(for: file)
        // The scratch file only, and its folder only if that is now empty
        // (rmdir refuses anything else): the folder may be a shared one.
        defer {
            try? FileManager.default.removeItem(at: scratch)
            rmdir(scratch.deletingLastPathComponent().path)
        }

        #expect(try volumeID(scratch.deletingLastPathComponent()) == volumeID(file))
        #expect(scratch.pathExtension == "mp4")
    }
}
