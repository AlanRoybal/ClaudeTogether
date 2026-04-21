import Foundation
import CollabTermC

/// Swift-side handle for a libcollabterm `ct_term`. Owns the pointer; caller
/// is responsible for calling `close()` (or letting the object die).
final class TermCore {
    private var handle: OpaquePointer?
    private(set) var cols: UInt16
    private(set) var rows: UInt16
    private var buf: [ct_cell]

    init?(cols: UInt16, rows: UInt16) {
        guard let h = ct_term_new(cols, rows) else { return nil }
        self.handle = h
        self.cols = cols
        self.rows = rows
        self.buf = [ct_cell](
            repeating: ct_cell(),
            count: Int(cols) * Int(rows))
    }

    deinit { close() }

    func close() {
        if let h = handle { ct_term_free(h) }
        handle = nil
    }

    func feed(_ bytes: [UInt8]) {
        guard let h = handle, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { p in
            ct_term_feed(h, p.baseAddress, p.count)
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard let h = handle else { return }
        _ = ct_term_resize(h, cols, rows)
        self.cols = cols
        self.rows = rows
        self.buf = [ct_cell](
            repeating: ct_cell(),
            count: Int(cols) * Int(rows))
    }

    /// Copies the current cell grid into the internal buffer and returns a
    /// read-only view. Valid until the next call to `snapshot()`.
    func snapshot() -> UnsafeBufferPointer<ct_cell> {
        guard let h = handle else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        buf.withUnsafeMutableBufferPointer { p in
            _ = ct_term_snapshot(h, p.baseAddress, p.count)
        }
        return buf.withUnsafeBufferPointer { $0 }
    }

    func cursor() -> (x: UInt16, y: UInt16) {
        guard let h = handle else { return (0, 0) }
        var x: UInt16 = 0
        var y: UInt16 = 0
        ct_term_cursor(h, &x, &y)
        return (x, y)
    }

    var dirtyEpoch: UInt32 {
        guard let h = handle else { return 0 }
        return ct_term_dirty_epoch(h)
    }
}
