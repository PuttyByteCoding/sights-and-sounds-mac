import Foundation

/// A file of secrets: keys and tokens, as JSON, readable only by the
/// user who owns it.
///
/// Not the Keychain, on purpose. This app is built unsigned and rebuilt
/// often, and a keychain item belongs to the binary that made it: the
/// system would ask leave again after every build. A file the user alone
/// can read is weaker against other software running as that user, and
/// is what an unsigned app can honestly offer.
enum SecretFile {
    enum Failure: Error, CustomStringConvertible {
        case unreadable(String, String)
        case unwritable(String, String)

        var description: String {
            switch self {
            case .unreadable(let path, let why): "\(path) could not be read: \(why)"
            case .unwritable(let path, let why): "\(path) could not be written: \(why)"
            }
        }
    }

    /// What the file holds, or nil when there is no file. A file that is
    /// there and cannot be read is an error, never "nothing": treated as
    /// nothing it would be written over, and every approval in it lost.
    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            // Tightened if something has loosened it since.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(type, from: Data(contentsOf: url))
        } catch {
            throw Failure.unreadable(url.path, "\(error)")
        }
    }

    /// Replace the file, whole or not at all, never readable by anyone
    /// else on the way: it is written beside itself with its permissions
    /// already set, then moved into place.
    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let draft = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            guard FileManager.default.createFile(
                atPath: draft.path, contents: data, attributes: [.posixPermissions: 0o600])
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(draft.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: draft)
            throw Failure.unwritable(url.path, "\(error)")
        }
    }
}
