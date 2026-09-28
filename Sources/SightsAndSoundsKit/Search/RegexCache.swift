import Foundation

/// Compiled patterns, shared. The recipe editor rebuilds its preview on
/// every keystroke, and a regex rule used to compile its pattern again
/// for every value it touched. `NSRegularExpression` is immutable and
/// safe to share across threads. A pattern that does not compile is
/// remembered as nil, so it is not retried either.
final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()

    private struct Key: Hashable {
        let pattern: String
        let options: NSRegularExpression.Options.RawValue
    }

    private let lock = NSLock()
    private var store: [Key: NSRegularExpression?] = [:]
    /// How many patterns were compiled — what the tests watch.
    private(set) var compilations = 0
    /// Patterns typed live in the editor pass through here one keystroke
    /// at a time; the cache starts over rather than growing without end.
    private let limit = 256

    func expression(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = Key(pattern: pattern, options: options.rawValue)
        return lock.withLock {
            if let cached = store[key] { return cached }
            if store.count >= limit { store.removeAll(keepingCapacity: true) }
            compilations += 1
            let compiled = try? NSRegularExpression(pattern: pattern, options: options)
            store[key] = compiled
            return compiled
        }
    }
}
