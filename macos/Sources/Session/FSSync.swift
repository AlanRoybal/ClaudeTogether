import Foundation
import CoreServices
import Darwin

/// Shared constants between the host-side watcher and the peer-side applier.
/// Mirrors `core/src/fs_sync.zig`.
enum FSSync {
    /// Hard cap on a single file's content. Files above this are skipped
    /// (host) / rejected (peer). Generous for text-heavy trees; avoids
    /// blowing past transport.max_frame_bytes with overhead.
    static let maxFileBytes: Int = 4 * 1024 * 1024

    /// Directory names that are never scanned on the host or written on the
    /// peer. Matches `excluded_dir_names` in fs_sync.zig.
    static let excludedDirNames: Set<String> = [
        ".git", ".svn", ".hg", ".DS_Store",
        "node_modules", ".build", ".zig-cache",
        "build", "target",
        ".next", ".cache", ".venv", "__pycache__",
    ]

    /// Structural validation: reject empty / absolute / `..` / NUL paths.
    /// Peers MUST run this before any filesystem op — a malicious host
    /// could otherwise write outside the chosen sync root.
    static func validateRelativePath(_ path: String) -> Bool {
        if path.isEmpty { return false }
        if path.hasPrefix("/") { return false }
        if path.contains("\0") { return false }
        if path.contains("\\") { return false }
        for comp in path.split(separator: "/", omittingEmptySubsequences: false) {
            if comp == ".." { return false }
        }
        return true
    }

    /// Read a file's `mtime` in nanoseconds since Unix epoch (signed). Returns
    /// nil if the path is missing or not a regular file.
    ///
    /// Note: both `stat` the struct type and `stat` the POSIX function live in
    /// Darwin. Unqualified works because Swift resolves by arity (0 args =
    /// struct init, 2 args = function); `Darwin.stat(cp, &st)` ambiguously
    /// binds to the struct's init first and then rejects the extra args.
    static func statFile(_ url: URL) -> (mtimeNs: Int64, size: Int64)? {
        var st = stat()
        let rc = url.path.withCString { cp in
            stat(cp, &st)
        }
        guard rc == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let ns = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(st.st_mtimespec.tv_nsec)
        return (ns, Int64(st.st_size))
    }
}

// MARK: - Host-side watcher -----------------------------------------------

/// Walks a session root on startup, emits an initial burst of `FsDelta.upsert`
/// frames, then subscribes to FSEvents and emits further deltas as files
/// change. 50ms latency matches the plan's debounce target. FS watching lives
/// in Swift (vs. Zig) because FSEventStream is a CoreServices API and the
/// platform SDK bindings are concise; the trade-off is documented in
/// `core/src/fs_sync.zig`.
@MainActor
final class FSSyncWatcher {
    private struct FileState: Equatable {
        var mtimeNs: Int64
        var size: Int64
    }

    let root: URL
    private var state: [String: FileState] = [:]
    private var stream: FSEventStreamRef?

    /// Called on the main queue for every delta. Host wiring forwards these
    /// to the session broadcast.
    var onDelta: ((FsDelta) -> Void)?

    init(root: URL) { self.root = root }

    deinit {
        // Direct cleanup — safe to call from deinit without MainActor hop
        // because the stream has no dispatch queue once invalidated.
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    /// Emit a full upsert sequence for every currently-tracked path. Used to
    /// bring a newly-joined peer up to speed.
    func enumerateSnapshot(_ handler: (FsDelta) -> Void) {
        for rel in state.keys.sorted() {
            guard let delta = buildUpsert(relative: rel) else { continue }
            handler(delta)
        }
    }

    var syncedFileCount: Int { state.count }

    func start() {
        scanInitial()
        startStream()
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
        state.removeAll(keepingCapacity: false)
    }

    // MARK: private

    private func scanInitial() {
        state.removeAll(keepingCapacity: true)
        walk(relative: "") { rel in
            let url = self.root.appendingPathComponent(rel)
            guard let s = FSSync.statFile(url) else { return }
            if s.size > Int64(FSSync.maxFileBytes) {
                NSLog("[ct/fs] skipping %@ (%lld bytes > cap)", rel, s.size)
                return
            }
            let fileState = FileState(mtimeNs: s.mtimeNs, size: s.size)
            self.state[rel] = fileState
            if let d = self.buildUpsert(relative: rel, state: fileState) {
                self.onDelta?(d)
            }
        }
    }

    private func startStream() {
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let paths = [root.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot)

        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<FSSyncWatcher>
                .fromOpaque(clientInfo).takeUnretainedValue()
            let cfArr = Unmanaged<CFArray>
                .fromOpaque(eventPaths).takeUnretainedValue()
            let arr = cfArr as NSArray
            var paths: [String] = []
            paths.reserveCapacity(numEvents)
            for v in arr {
                if let s = v as? String { paths.append(s) }
            }
            // FSEvents callback arrives on the dispatch queue we set below —
            // DispatchQueue.main — so MainActor-isolated handlers are safe to
            // invoke after hopping through assumeIsolated.
            MainActor.assumeIsolated {
                watcher.handleEvents(paths: paths)
            }
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback, &ctx, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags)
        else {
            NSLog("[ct/fs] FSEventStreamCreate failed")
            return
        }

        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        self.stream = s
    }

    private func handleEvents(paths: [String]) {
        let rootPath = root.path
        var seen: Set<String> = []

        for absPath in paths {
            guard absPath == rootPath || absPath.hasPrefix(rootPath + "/") else {
                continue
            }
            let rel = relativePath(for: absPath)

            // Respect the exclusion list: anything whose leading component
            // (or any segment) is excluded is dropped. We still need to emit
            // a delete if we were previously tracking it — which we won't be,
            // because scan skips excluded dirs — so ignoring is safe.
            if rel.split(separator: "/").contains(where: {
                FSSync.excludedDirNames.contains(String($0))
            }) {
                continue
            }

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: absPath, isDirectory: &isDir)

            if !exists {
                // Gone. Delete anything we had tracked under this prefix.
                let prefix = rel.isEmpty ? "" : rel + "/"
                var toDelete: [String] = []
                for key in state.keys where key == rel || key.hasPrefix(prefix) {
                    toDelete.append(key)
                }
                for key in toDelete {
                    state.removeValue(forKey: key)
                    onDelta?(FsDelta(op: .delete, path: key,
                                     mtimeNs: 0, content: Data()))
                    seen.insert(key)
                }
                continue
            }

            if isDir.boolValue {
                // Walk the directory and diff each file against state.
                walk(relative: rel) { child in
                    if !seen.contains(child) {
                        self.processFile(rel: child, seen: &seen)
                    }
                }
                // Detect deletes inside this directory that FSEvents may have
                // coalesced: anything tracked under `rel/` that we didn't
                // just re-stat is gone.
                let prefix = rel.isEmpty ? "" : rel + "/"
                var lost: [String] = []
                for key in state.keys
                where (rel.isEmpty || key == rel || key.hasPrefix(prefix))
                    && !seen.contains(key)
                {
                    let abs = root.appendingPathComponent(key).path
                    if !FileManager.default.fileExists(atPath: abs) {
                        lost.append(key)
                    }
                }
                for key in lost {
                    state.removeValue(forKey: key)
                    onDelta?(FsDelta(op: .delete, path: key,
                                     mtimeNs: 0, content: Data()))
                    seen.insert(key)
                }
            } else {
                if !seen.contains(rel) {
                    processFile(rel: rel, seen: &seen)
                }
            }
        }
    }

    private func processFile(rel: String, seen: inout Set<String>) {
        seen.insert(rel)
        let url = root.appendingPathComponent(rel)
        guard let s = FSSync.statFile(url) else {
            if state.removeValue(forKey: rel) != nil {
                onDelta?(FsDelta(op: .delete, path: rel,
                                 mtimeNs: 0, content: Data()))
            }
            return
        }
        if s.size > Int64(FSSync.maxFileBytes) {
            if state.removeValue(forKey: rel) != nil {
                NSLog("[ct/fs] %@ grew past cap; sending delete to peers", rel)
                onDelta?(FsDelta(op: .delete, path: rel,
                                 mtimeNs: 0, content: Data()))
            }
            return
        }
        let next = FileState(mtimeNs: s.mtimeNs, size: s.size)
        if state[rel] == next { return }
        state[rel] = next
        if let d = buildUpsert(relative: rel, state: next) {
            onDelta?(d)
        }
    }

    private func buildUpsert(relative rel: String,
                             state cached: FileState? = nil) -> FsDelta?
    {
        let url = root.appendingPathComponent(rel)
        let fs = cached ?? FSSync.statFile(url).map {
            FileState(mtimeNs: $0.mtimeNs, size: $0.size)
        }
        guard let fs else { return nil }
        if fs.size > Int64(FSSync.maxFileBytes) { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return FsDelta(
            op: .upsert,
            path: rel,
            mtimeNs: fs.mtimeNs,
            content: data)
    }

    private func walk(relative prefix: String, visit: (String) -> Void) {
        let basePath = prefix.isEmpty
            ? root.path
            : root.appendingPathComponent(prefix).path
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: basePath)
        else {
            return
        }
        for name in entries {
            if FSSync.excludedDirNames.contains(name) { continue }
            let rel = prefix.isEmpty ? name : prefix + "/" + name
            let full = root.appendingPathComponent(rel).path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: full, isDirectory: &isDir)
            else {
                continue
            }
            if isDir.boolValue {
                walk(relative: rel, visit: visit)
            } else {
                visit(rel)
            }
        }
    }

    private func relativePath(for absPath: String) -> String {
        let rootPath = root.path
        if absPath == rootPath { return "" }
        if absPath.hasPrefix(rootPath + "/") {
            return String(absPath.dropFirst(rootPath.count + 1))
        }
        return absPath
    }
}

// MARK: - Peer-side applier ------------------------------------------------

/// Receives `FsDelta` frames from the session and writes them into a chosen
/// local root. Writes are atomic (tmp + rename) so concurrent readers never
/// observe partial content. Tracks the mtime we last wrote so we can detect
/// when an external tool (or the user) edited a file between deltas — the
/// next delta will clobber that edit, and we surface it as a warning.
@MainActor
final class FSSyncApplier {
    let root: URL

    /// Paths we expect to remain untouched between deltas, keyed by the
    /// relative path we wrote. Value is the on-disk mtime right after our
    /// write (read back from stat, not the wire delta — filesystem rounding
    /// would otherwise produce false positives).
    private var expectedMtimes: [String: Int64] = [:]

    /// Called (on main) for every delta we successfully apply. Count, not
    /// the payload — the UI cares about activity, not content.
    var onApply: (() -> Void)?

    /// Called with the relative path when we detected the file had been
    /// modified locally between our last write and the current delta.
    var onExternalEdit: ((String) -> Void)?

    init(root: URL) { self.root = root }

    func apply(_ delta: FsDelta) {
        guard FSSync.validateRelativePath(delta.path) else {
            NSLog("[ct/fs] rejected unsafe path from host: %@", delta.path)
            return
        }
        // Exclusion list applies at apply time too — defense in depth.
        if delta.path.split(separator: "/").contains(where: {
            FSSync.excludedDirNames.contains(String($0))
        }) {
            return
        }

        let target = root.appendingPathComponent(delta.path)

        if let expected = expectedMtimes[delta.path],
           let current = FSSync.statFile(target)?.mtimeNs,
           current != expected
        {
            onExternalEdit?(delta.path)
        }

        switch delta.op {
        case .upsert:
            applyUpsert(relative: delta.path,
                        target: target,
                        content: delta.content,
                        mtimeNs: delta.mtimeNs)
        case .delete:
            applyDelete(relative: delta.path, target: target)
        }
    }

    // MARK: private

    private func applyUpsert(relative rel: String,
                             target: URL,
                             content: Data,
                             mtimeNs: Int64)
    {
        if content.count > FSSync.maxFileBytes {
            NSLog("[ct/fs] refused oversize upsert %@ (%d bytes)",
                  rel, content.count)
            return
        }

        let parent = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true)
        } catch {
            NSLog("[ct/fs] mkdir %@ failed: %@",
                  parent.path, "\(error)")
            return
        }

        let tmp = parent.appendingPathComponent(
            ".ct-tmp-" + UUID().uuidString.prefix(8))
        do {
            try content.write(to: tmp, options: .atomic)
        } catch {
            NSLog("[ct/fs] write %@ failed: %@", tmp.path, "\(error)")
            return
        }

        let date = Date(timeIntervalSince1970: Double(mtimeNs) / 1e9)
        try? FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: tmp.path)

        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: tmp, to: target)
        } catch {
            NSLog("[ct/fs] rename to %@ failed: %@", target.path, "\(error)")
            try? FileManager.default.removeItem(at: tmp)
            return
        }

        // Read back the actual on-disk mtime so future diffs compare against
        // what's really there (avoids false-positive external-edit alerts
        // caused by fs mtime-rounding).
        if let actual = FSSync.statFile(target)?.mtimeNs {
            expectedMtimes[rel] = actual
        } else {
            expectedMtimes[rel] = mtimeNs
        }
        onApply?()
    }

    private func applyDelete(relative rel: String, target: URL) {
        if FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                NSLog("[ct/fs] delete %@ failed: %@",
                      target.path, "\(error)")
                return
            }
        }
        expectedMtimes.removeValue(forKey: rel)
        onApply?()
    }
}
