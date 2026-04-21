import Foundation
import Darwin
import CollabTermC

/// Owns a PTY master fd + child pid from libcollabterm.
/// Provides an onOutput callback for incoming bytes and a send(_:) for keystrokes.
final class PTYSession {
    private(set) var fd: Int32 = -1
    private(set) var pid: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "ct.pty.read")

    /// Called on the main queue with each chunk of PTY output.
    var onOutput: (([UInt8]) -> Void)?
    /// Called on the main queue when the child process exits.
    var onExit: (() -> Void)?

    @discardableResult
    func spawn(shell: String = "/bin/zsh",
               cwd: String?,
               cols: UInt16 = 80,
               rows: UInt16 = 24) -> Bool {
        // argv: {shell, "-l", NULL}
        let shellC = strdup(shell)
        let loginFlag = strdup("-l")
        defer {
            free(shellC)
            free(loginFlag)
        }
        var argv: [UnsafePointer<CChar>?] = [
            UnsafePointer(shellC),
            UnsafePointer(loginFlag),
            nil,
        ]

        var outFd: Int32 = -1
        var outPid: Int32 = -1
        let rc: Int32 = argv.withUnsafeMutableBufferPointer { buf -> Int32 in
            let raw = UnsafeRawPointer(buf.baseAddress!)
                .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            if let cwd = cwd {
                return cwd.withCString { cwdC in
                    ct_pty_spawn(raw, cwdC, cols, rows, &outFd, &outPid)
                }
            } else {
                return ct_pty_spawn(raw, nil, cols, rows, &outFd, &outPid)
            }
        }
        guard rc == 0 else { return false }
        self.fd = outFd
        self.pid = outPid
        startReading()
        return true
    }

    func send(_ bytes: [UInt8]) {
        guard fd >= 0, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buf in
            var written = 0
            while written < buf.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: written), buf.count - written)
                if n <= 0 {
                    if errno == EINTR { continue }
                    break
                }
                written += n
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard fd >= 0 else { return }
        _ = ct_pty_resize(fd, cols, rows)
    }

    var isRaw: Bool {
        guard fd >= 0 else { return false }
        return ct_pty_is_raw(fd) == 1
    }

    func terminate() {
        readSource?.cancel()
        readSource = nil
        if pid > 0 { ct_pty_kill(pid) }
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        pid = -1
    }

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                Darwin.read(self.fd, p.baseAddress, p.count)
            }
            if n > 0 {
                let chunk = Array(buf.prefix(n))
                DispatchQueue.main.async { self.onOutput?(chunk) }
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                DispatchQueue.main.async { self.onExit?() }
                self.readSource?.cancel()
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            // fd close handled in terminate()
            _ = self
        }
        self.readSource = src
        src.resume()
    }

    deinit { terminate() }
}
