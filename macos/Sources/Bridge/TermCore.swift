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

    var isUsingAlternateScreen: Bool {
        guard let h = handle else { return false }
        return ct_term_is_using_alt(h) == 1
    }

    var dirtyEpoch: UInt32 {
        guard let h = handle else { return 0 }
        return ct_term_dirty_epoch(h)
    }

    // MARK: mouse-reporting modes
    //
    // The running app sets/clears these via DECSET 1000/1002/1003/1006/1015.
    // The Zig core just records the bits; encoding macOS NSEvents to PTY
    // input bytes happens in `MetalTerminalNSView`.
    //
    // Bit values mirror `CT_MOUSE_*` macros in `collabterm.h`. We hard-code
    // them here so Swift doesn't depend on whether the importer translates
    // the parenthesized `(1u << N)` macros into typed constants — that
    // behavior can be inconsistent across Xcode releases.

    /// Bitmask values matching `CT_MOUSE_*` in `collabterm.h`.
    enum MouseMode {
        static let x10: UInt32   = 1 << 0  // DECSET 1000
        static let drag: UInt32  = 1 << 1  // DECSET 1002
        static let move: UInt32  = 1 << 2  // DECSET 1003
        static let sgr: UInt32   = 1 << 3  // DECSET 1006
        static let urxvt: UInt32 = 1 << 4  // DECSET 1015
    }

    /// Raw bitmask. See `MouseMode` for the bit layout.
    var mouseModeBits: UInt32 {
        guard let h = handle else { return 0 }
        return ct_term_mouse_mode(h)
    }

    /// True if any mouse-reporting mode is active.
    var mouseEnabled: Bool { mouseModeBits != 0 }

    /// DECSET 1006 — xterm SGR encoding. The only encoding we currently
    /// emit; if this bit is missing the running app likely expects the
    /// legacy X10 byte format which we don't synthesize today.
    var sgrMouse: Bool { mouseModeBits & MouseMode.sgr != 0 }

    /// DECSET 1000 — report press/release only.
    var x10Mouse: Bool { mouseModeBits & MouseMode.x10 != 0 }

    /// DECSET 1002 — press/release + motion while a button is held.
    var dragMouse: Bool { mouseModeBits & MouseMode.drag != 0 }

    /// DECSET 1003 — press/release + every motion, no button required.
    var anyMotionMouse: Bool { mouseModeBits & MouseMode.move != 0 }
}
