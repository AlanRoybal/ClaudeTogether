import Foundation

/// Persisted, per-app command history for the shared input line.
/// Stores up to `maxEntries` unique commands, in insertion order with
/// the most-recent at the end. Re-recording an existing entry moves it
/// to the most-recent position. Persisted to UserDefaults under
/// `userDefaultsKey` so history survives app relaunch.
@MainActor
final class CommandHistory: ObservableObject {
    static let userDefaultsKey = "ClaudeTogether.cmdHistory"
    static let maxEntries = 100

    /// All persisted commands, oldest first. Public so the autocomplete
    /// pipeline can iterate without going through a copy.
    @Published private(set) var entries: [String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.array(forKey: Self.userDefaultsKey) as? [String]
        self.entries = (raw ?? []).suffix(Self.maxEntries).map { $0 }
    }

    /// Capture a command line that just got dispatched. Empty /
    /// whitespace-only commands are ignored. Re-recording an existing
    /// entry moves it to the most-recent end so recency wins on ties.
    func record(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = entries.firstIndex(of: trimmed) {
            entries.remove(at: idx)
        }
        entries.append(trimmed)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        defaults.set(entries, forKey: Self.userDefaultsKey)
    }

    /// Iterate entries from most-recent to oldest.
    var mostRecentFirst: [String] {
        entries.reversed()
    }

    /// Map of command -> recency rank (0 = most recent). Used by the
    /// fuzzy matcher to break score ties.
    var recencyRank: [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(entries.count)
        for (idx, cmd) in entries.reversed().enumerated() {
            out[cmd] = idx
        }
        return out
    }
}
