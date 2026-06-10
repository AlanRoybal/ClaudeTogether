import Foundation
import CollabTermC

/// Swift-side handle for a libcollabterm `ct_term`. Owns the pointer; caller
/// is responsible for calling `close()` (or letting the object die).
final class TermCore {
    private var handle: OpaquePointer?
    private(set) var cols: UInt16
    private(set) var rows: UInt16
    // Manually-managed storage so `snapshot()` can hand out a pointer that
    // stays valid until the next resize. Escaping a pointer out of an Array's
    // withUnsafeBufferPointer is undefined behavior.
    private var buf: UnsafeMutableBufferPointer<ct_cell>

    init?(cols: UInt16, rows: UInt16) {
        guard let h = ct_term_new(cols, rows) else { return nil }
        self.handle = h
        self.cols = cols
        self.rows = rows
        self.buf = .allocate(capacity: Int(cols) * Int(rows))
        self.buf.initialize(repeating: ct_cell())
    }

    deinit {
        close()
        buf.deallocate()
    }

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

    func resize(cols: UInt16, rows: UInt16, preserveTop: Bool = false) {
        guard let h = handle else { return }
        if preserveTop {
            _ = ct_term_resize_preserving_top(h, cols, rows)
        } else {
            _ = ct_term_resize(h, cols, rows)
        }
        self.cols = cols
        self.rows = rows
        buf.deallocate()
        buf = .allocate(capacity: Int(cols) * Int(rows))
        buf.initialize(repeating: ct_cell())
    }

    /// Copies the current cell grid into the internal buffer and returns a
    /// read-only view. Valid until the next `resize` or deinit.
    func snapshot() -> UnsafeBufferPointer<ct_cell> {
        guard let h = handle else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        _ = ct_term_snapshot(h, buf.baseAddress, buf.count)
        return UnsafeBufferPointer(buf)
    }

    var scrollbackLength: Int {
        guard let h = handle else { return 0 }
        return Int(ct_term_scrollback_len(h))
    }

    func copyScrollback(startRow: Int,
                        rowCount: Int,
                        into out: inout [ct_cell]) -> Int
    {
        guard let h = handle,
              startRow >= 0,
              rowCount > 0,
              !out.isEmpty
        else {
            return 0
        }
        return out.withUnsafeMutableBufferPointer { p in
            Int(ct_term_scrollback_snapshot(
                h,
                UInt32(min(startRow, Int(UInt32.max))),
                UInt32(min(rowCount, Int(UInt32.max))),
                p.baseAddress,
                p.count))
        }
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

    /// True when the running app has enabled bracketed paste mode (DECSET ?2004h).
    var bracketedPasteMode: Bool {
        guard let h = handle else { return false }
        return ct_term_bracketed_paste_mode(h) == 1
    }

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

    /// Returns the OSC 8 URL for the cell at (col, row), or nil if the cell
    /// carries no hyperlink or the URL is not a valid URL.
    func cellUrl(col: UInt16, row: UInt16) -> URL? {
        guard let h = handle else { return nil }
        var buf = [UInt8](repeating: 0, count: 2048)
        let len = buf.withUnsafeMutableBufferPointer { p in
            ct_term_cell_url(h, col, row, p.baseAddress, p.count)
        }
        // ct_term_cell_url returns the FULL url length, which can exceed the
        // buffer; only `min(len, cap)` bytes were copied. Without the clamp a
        // hostile >2 KB OSC 8 URL traps the range subscript.
        let n = min(len, buf.count)
        guard n > 0,
              let str = String(bytes: buf[..<n], encoding: .utf8),
              let url = URL(string: str)
        else { return nil }
        return url
    }
}
