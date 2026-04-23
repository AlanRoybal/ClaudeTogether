import Foundation

struct FSSyncHostUpdate {
    var deltas: [FSSyncDelta]
    var snapshot: [FSSnapshotEntry]?
}

private struct FSSyncLocalEntry: Equatable {
    var kind: FSSnapshotEntryKind
    var size: UInt64
    var modifiedAtNanoseconds: UInt64
}

final class FSSyncWatcher {
    private let rootURL: URL
    private var lastEntries: [String: FSSyncLocalEntry] = [:]
    private let fileManager = FileManager.default

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func fullSync() -> FSSyncHostUpdate {
        let current = scan()
        lastEntries = current
        return FSSyncHostUpdate(
            deltas: fullSyncDeltas(for: current),
            snapshot: snapshotEntries(for: current))
    }

    func incrementalSync() -> FSSyncHostUpdate? {
        let current = scan()
        let deltas = diff(from: lastEntries, to: current)
        lastEntries = current
        guard !deltas.isEmpty else { return nil }
        return FSSyncHostUpdate(deltas: deltas, snapshot: nil)
    }

    private func scan() -> [String: FSSyncLocalEntry] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                NSLog("[ct] fs scan skipped %@: %@", url.path, error.localizedDescription)
                return true
            })
        else {
            return [:]
        }

        var entries: [String: FSSyncLocalEntry] = [:]
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            guard let relativePath = SessionPathResolver.relativePath(
                rootURL: rootURL,
                childURL: standardized)
            else {
                continue
            }

            guard let values = try? standardized.resourceValues(forKeys: Set(keys)) else {
                continue
            }

            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            if values.isDirectory == true {
                entries[relativePath] = FSSyncLocalEntry(
                    kind: .directory,
                    size: 0,
                    modifiedAtNanoseconds: 0)
                continue
            }

            guard values.isRegularFile == true else { continue }
            let modifiedAt = values.contentModificationDate?
                .timeIntervalSince1970 ?? 0
            entries[relativePath] = FSSyncLocalEntry(
                kind: .file,
                size: UInt64(values.fileSize ?? 0),
                modifiedAtNanoseconds: UInt64(max(0, modifiedAt) * 1_000_000_000))
        }
        return entries
    }

    private func fullSyncDeltas(for entries: [String: FSSyncLocalEntry]) -> [FSSyncDelta] {
        let directories = entries
            .filter { $0.value.kind == .directory }
            .map(\.key)
            .sorted(by: Self.shallowPathOrder)
        let files = entries
            .filter { $0.value.kind == .file }
            .map(\.key)
            .sorted()

        var deltas: [FSSyncDelta] = directories.map {
            FSSyncDelta(kind: .ensureDirectory, path: $0)
        }
        for path in files {
            guard let data = fileContents(at: path) else { continue }
            deltas.append(FSSyncDelta(kind: .upsertFile, path: path, data: data))
        }
        return deltas
    }

    private func snapshotEntries(for entries: [String: FSSyncLocalEntry]) -> [FSSnapshotEntry] {
        entries.keys.sorted(by: Self.shallowPathOrder).compactMap { path in
            guard let entry = entries[path] else { return nil }
            return FSSnapshotEntry(kind: entry.kind, path: path)
        }
    }

    private func diff(from oldEntries: [String: FSSyncLocalEntry],
                      to newEntries: [String: FSSyncLocalEntry]) -> [FSSyncDelta]
    {
        let deletedPaths = oldEntries.keys
            .filter { newEntries[$0] == nil }
            .sorted(by: Self.deepPathOrder)

        let createdOrChangedDirectories = newEntries.keys
            .filter { path in
                guard let newEntry = newEntries[path], newEntry.kind == .directory else {
                    return false
                }
                return oldEntries[path] != newEntry
            }
            .sorted(by: Self.shallowPathOrder)

        let createdOrChangedFiles = newEntries.keys
            .filter { path in
                guard let newEntry = newEntries[path], newEntry.kind == .file else {
                    return false
                }
                return oldEntries[path] != newEntry
            }
            .sorted()

        var deltas = deletedPaths.map {
            FSSyncDelta(kind: .deletePath, path: $0)
        }
        deltas.append(contentsOf: createdOrChangedDirectories.map {
            FSSyncDelta(kind: .ensureDirectory, path: $0)
        })
        for path in createdOrChangedFiles {
            guard let data = fileContents(at: path) else { continue }
            deltas.append(FSSyncDelta(kind: .upsertFile, path: path, data: data))
        }
        return deltas
    }

    private func fileContents(at sessionPath: String) -> Data? {
        guard let url = SessionPathResolver.resolve(rootURL: rootURL, sessionPath: sessionPath) else {
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            NSLog("[ct] fs sync read failed %@: %@", url.path, error.localizedDescription)
            return nil
        }
    }

    private static func shallowPathOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDepth = lhs.split(separator: "/").count
        let rhsDepth = rhs.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhs < rhs
    }

    private static func deepPathOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDepth = lhs.split(separator: "/").count
        let rhsDepth = rhs.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
        return lhs > rhs
    }
}
