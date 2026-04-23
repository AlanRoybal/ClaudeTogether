import Foundation

enum SessionPathResolver {
    static func resolve(rootPath: String?, sessionPath: String) -> URL? {
        guard let rootPath else { return nil }
        return resolve(
            rootURL: URL(fileURLWithPath: rootPath, isDirectory: true),
            sessionPath: sessionPath)
    }

    static func resolve(rootURL: URL, sessionPath: String) -> URL? {
        guard !sessionPath.isEmpty,
              !sessionPath.hasPrefix("/"),
              !sessionPath.contains("\\"),
              !sessionPath.contains("\0")
        else {
            return nil
        }

        let root = rootURL.standardizedFileURL
        let parts = sessionPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            return nil
        }

        let resolved = parts.reduce(root) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.standardizedFileURL

        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(rootPrefix) else {
            return nil
        }
        return resolved
    }

    static func relativePath(rootURL: URL, childURL: URL) -> String? {
        let root = rootURL.standardizedFileURL
        let child = childURL.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard child.path.hasPrefix(rootPrefix) else { return nil }
        let relative = String(child.path.dropFirst(rootPrefix.count))
        return relative.isEmpty ? nil : relative
    }
}

final class FSSyncApplier {
    private struct StoredState: Codable {
        var rootPath: String
        var managedPaths: [String: FSSnapshotEntryKind]
    }

    private let fileManager = FileManager.default
    private var rootURL: URL?
    private var managedPaths: [String: FSSnapshotEntryKind] = [:]

    func configure(rootPath: String?) {
        guard let rootPath else {
            rootURL = nil
            managedPaths = [:]
            return
        }
        let standardized = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
        rootURL = standardized
        managedPaths = loadState(for: standardized).managedPaths
    }

    func apply(_ delta: FSSyncDelta) {
        guard rootURL != nil else { return }
        switch delta.kind {
        case .upsertFile:
            applyUpsertFile(at: delta.path, data: delta.data)
        case .ensureDirectory:
            applyEnsureDirectory(at: delta.path)
        case .deletePath:
            deleteManagedPath(delta.path)
        }
        persistState()
    }

    func reconcile(snapshot entries: [FSSnapshotEntry]) {
        let manifest = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.kind) })
        let stalePaths = managedPaths.keys
            .filter { manifest[$0] == nil }
            .sorted { self.deepPathOrder($0, $1) }

        for path in stalePaths {
            deleteManagedPath(path)
        }

        for (path, kind) in manifest {
            if managedPaths[path] != nil {
                managedPaths[path] = kind
            }
        }
        persistState()
    }

    private func applyUpsertFile(at sessionPath: String, data: Data) {
        guard let url = resolve(sessionPath) else { return }
        guard prepareParentDirectory(for: sessionPath) else { return }

        if fileManager.fileExists(atPath: url.path) {
            var isDirectory = ObjCBool(false)
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                deleteManagedDescendants(of: sessionPath)
                if !removeDirectoryIfEmpty(url, sessionPath: sessionPath) {
                    managedPaths.removeValue(forKey: sessionPath)
                    NSLog("[ct] fs sync preserved local directory conflict at %@", url.path)
                    return
                }
            }
        }

        do {
            try data.write(to: url, options: .atomic)
            managedPaths = managedPaths.filter { key, _ in
                key == sessionPath || !key.hasPrefix(sessionPath + "/")
            }
            managedPaths[sessionPath] = .file
        } catch {
            NSLog("[ct] fs sync write failed %@: %@", url.path, error.localizedDescription)
        }
    }

    private func applyEnsureDirectory(at sessionPath: String) {
        guard let url = resolve(sessionPath) else { return }
        guard prepareParentDirectory(for: sessionPath) else { return }

        if fileManager.fileExists(atPath: url.path) {
            var isDirectory = ObjCBool(false)
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    NSLog("[ct] fs sync remove file failed %@: %@", url.path,
                          error.localizedDescription)
                    return
                }
            }
        }

        do {
            try fileManager.createDirectory(at: url,
                                            withIntermediateDirectories: true,
                                            attributes: nil)
            managedPaths[sessionPath] = .directory
        } catch {
            NSLog("[ct] fs sync mkdir failed %@: %@", url.path, error.localizedDescription)
        }
    }

    private func deleteManagedPath(_ sessionPath: String) {
        guard resolve(sessionPath) != nil else { return }

        let descendants = managedPaths.keys
            .filter { $0 == sessionPath || $0.hasPrefix(sessionPath + "/") }
            .sorted { self.deepPathOrder($0, $1) }

        for path in descendants {
            guard let url = resolve(path) else { continue }
            let kind = managedPaths[path]
            switch kind {
            case .file:
                if fileManager.fileExists(atPath: url.path) {
                    var isDirectory = ObjCBool(false)
                    fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    if isDirectory.boolValue {
                        _ = removeDirectoryIfEmpty(url, sessionPath: path)
                    } else {
                        try? fileManager.removeItem(at: url)
                    }
                }
                managedPaths.removeValue(forKey: path)
            case .directory:
                _ = removeDirectoryIfEmpty(url, sessionPath: path)
                managedPaths.removeValue(forKey: path)
            case nil:
                break
            }
        }
    }

    private func deleteManagedDescendants(of sessionPath: String) {
        let descendants = managedPaths.keys
            .filter { $0.hasPrefix(sessionPath + "/") }
            .sorted { self.deepPathOrder($0, $1) }
        for path in descendants {
            deleteManagedPath(path)
        }
    }

    private func prepareParentDirectory(for sessionPath: String) -> Bool {
        let components = sessionPath.split(separator: "/")
        guard components.count > 1 else { return true }

        var current = ""
        for component in components.dropLast() {
            current = current.isEmpty ? String(component) : current + "/" + component
            guard let url = resolve(current) else { return false }
            if fileManager.fileExists(atPath: url.path) {
                var isDirectory = ObjCBool(false)
                fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                if isDirectory.boolValue { continue }
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    NSLog("[ct] fs sync parent conflict at %@: %@",
                          url.path, error.localizedDescription)
                    return false
                }
            }
            do {
                try fileManager.createDirectory(at: url,
                                                withIntermediateDirectories: false,
                                                attributes: nil)
                managedPaths[current] = .directory
            } catch {
                if !fileManager.fileExists(atPath: url.path) {
                    NSLog("[ct] fs sync mkdir failed %@: %@", url.path,
                          error.localizedDescription)
                    return false
                }
            }
        }
        return true
    }

    private func removeDirectoryIfEmpty(_ url: URL, sessionPath: String) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return true
        }
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: url.path)
            guard contents.isEmpty else { return false }
            try fileManager.removeItem(at: url)
            managedPaths.removeValue(forKey: sessionPath)
            return true
        } catch {
            NSLog("[ct] fs sync rmdir failed %@: %@", url.path, error.localizedDescription)
            return false
        }
    }

    private func resolve(_ sessionPath: String) -> URL? {
        guard let rootURL else { return nil }
        return SessionPathResolver.resolve(rootURL: rootURL, sessionPath: sessionPath)
    }

    private func persistState() {
        guard let rootURL else { return }
        guard let url = stateURL(for: rootURL) else { return }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil)
            let data = try JSONEncoder().encode(StoredState(
                rootPath: rootURL.path,
                managedPaths: managedPaths))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[ct] fs sync state save failed %@: %@", url.path,
                  error.localizedDescription)
        }
    }

    private func loadState(for rootURL: URL) -> StoredState {
        guard let url = stateURL(for: rootURL),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(StoredState.self, from: data),
              state.rootPath == rootURL.path
        else {
            return StoredState(rootPath: rootURL.path, managedPaths: [:])
        }
        return state
    }

    private func stateURL(for rootURL: URL) -> URL? {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
        else {
            return nil
        }
        let key = stableKey(for: rootURL.path)
        return appSupport
            .appendingPathComponent("ClaudeTogether", isDirectory: true)
            .appendingPathComponent("FileSync", isDirectory: true)
            .appendingPathComponent(key + ".json", isDirectory: false)
    }

    private func stableKey(for string: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func deepPathOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDepth = lhs.split(separator: "/").count
        let rhsDepth = rhs.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
        return lhs > rhs
    }
}
