import Foundation
import AppKit
import CollabTermC

/// Identifies a participant whose cursor is drawn on the grid. Phase 2 ships
/// with a single local user; Phase 3 adds one entry per connected peer.
struct UserCursor: Identifiable, Equatable {
    let id: UUID
    var col: UInt16
    var row: UInt16
    /// 0xRRGGBB. Local user defaults to the terminal fg (handled by the
    /// renderer via inversion), peers get a distinct hue.
    var color: UInt32
    var isLocal: Bool
}

/// Observable wrapper around `TermCore`. Holds the set of user cursors drawn
/// over the grid. The renderer reads the Zig-owned cell buffer directly via
/// `snapshot()`; this model exists so session code (Phase 3) has a single
/// place to mutate shared state.
final class GridModel: ObservableObject {
    struct InputOverlayCursor {
        var id: UUID
        var offset: Int
        var color: UInt32
        var isLocal: Bool
    }

    private struct InputOverlay {
        var anchorCol: UInt16
        var anchorRow: UInt16
        var textScalars: [UnicodeScalar]
        var cursors: [InputOverlayCursor]
    }

    let term: TermCore
    let localCursorID = UUID()
    private var overlay: InputOverlay?
    private var overlaySnapshot: [ct_cell] = []

    /// Ordered list of cursors. Local user is always present at index 0.
    @Published private(set) var cursors: [UserCursor]

    /// Bumped whenever the grid or cursor state changes. Currently advisory —
    /// the renderer redraws every frame — but lets SwiftUI views bind to it.
    @Published private(set) var epoch: UInt32 = 0

    init?(cols: UInt16, rows: UInt16) {
        guard let term = TermCore(cols: cols, rows: rows) else { return nil }
        self.term = term
        self.cursors = [UserCursor(
            id: UUID(), col: 0, row: 0,
            color: 0xFFFFFF, isLocal: true)]
        // Stable ID for the local cursor so Phase 3 session code can update
        // it in-place by matching `isLocal`.
        self.cursors[0] = UserCursor(
            id: localCursorID, col: 0, row: 0,
            color: 0xFFFFFF, isLocal: true)
    }

    var cols: UInt16 { term.cols }
    var rows: UInt16 { term.rows }
    var isUsingAlternateScreen: Bool { term.isUsingAlternateScreen }

    func feed(_ bytes: [UInt8]) {
        term.feed(bytes)
        if overlay == nil {
            syncLocalCursor()
        } else {
            syncOverlayCursors()
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        term.resize(cols: cols, rows: rows)
        if overlay == nil {
            syncLocalCursor()
        } else {
            syncOverlayCursors()
        }
    }

    func snapshot() -> UnsafeBufferPointer<ct_cell> {
        let base = term.snapshot()
        guard let overlay else { return base }

        if overlaySnapshot.count != base.count {
            overlaySnapshot = [ct_cell](repeating: ct_cell(), count: base.count)
        }
        for i in 0..<base.count {
            overlaySnapshot[i] = base[i]
        }

        guard let anchorIndex = linearIndex(
            col: overlay.anchorCol,
            row: overlay.anchorRow)
        else {
            return overlaySnapshot.withUnsafeBufferPointer { $0 }
        }

        let styleCell = overlaySnapshot[anchorIndex]
        let blank = blankCell(from: styleCell)
        let maxCursorOffset = overlay.cursors.map(\.offset).max() ?? 0
        let span = max(1, max(overlay.textScalars.count, maxCursorOffset + 1))

        for offset in 0..<span {
            guard let idx = linearIndex(
                forOffset: offset,
                anchorCol: overlay.anchorCol,
                anchorRow: overlay.anchorRow)
            else {
                break
            }
            overlaySnapshot[idx] = blank
        }

        for (offset, scalar) in overlay.textScalars.enumerated() {
            guard let idx = linearIndex(
                forOffset: offset,
                anchorCol: overlay.anchorCol,
                anchorRow: overlay.anchorRow)
            else {
                break
            }
            var cell = blank
            cell.codepoint = UInt32(scalar.value)
            overlaySnapshot[idx] = cell
        }

        return overlaySnapshot.withUnsafeBufferPointer { $0 }
    }

    func setInputOverlay(anchorCol: UInt16,
                         anchorRow: UInt16,
                         text: String,
                         cursors: [InputOverlayCursor])
    {
        overlay = InputOverlay(
            anchorCol: anchorCol,
            anchorRow: anchorRow,
            textScalars: Array(text.unicodeScalars),
            cursors: cursors)
        syncOverlayCursors()
    }

    func clearInputOverlay() {
        overlay = nil
        syncLocalCursor()
        cursors.removeAll { !$0.isLocal }
        epoch &+= 1
    }

    /// Updates or inserts a peer cursor. Called by session code when a
    /// `CursorPos` frame arrives from a peer.
    func upsertPeerCursor(id: UUID, col: UInt16, row: UInt16, color: UInt32) {
        if let i = cursors.firstIndex(where: { $0.id == id }) {
            cursors[i].col = col
            cursors[i].row = row
            cursors[i].color = color
        } else {
            cursors.append(UserCursor(
                id: id, col: col, row: row,
                color: color, isLocal: false))
        }
        epoch &+= 1
    }

    func removePeerCursor(id: UUID) {
        cursors.removeAll { $0.id == id && !$0.isLocal }
        epoch &+= 1
    }

    private func syncOverlayCursors() {
        guard let overlay else {
            syncLocalCursor()
            return
        }

        var next: [UserCursor] = []
        next.reserveCapacity(overlay.cursors.count)
        for cursor in overlay.cursors {
            let position = gridPosition(
                forOffset: cursor.offset,
                anchorCol: overlay.anchorCol,
                anchorRow: overlay.anchorRow)
            next.append(UserCursor(
                id: cursor.id,
                col: position.col,
                row: position.row,
                color: cursor.color,
                isLocal: cursor.isLocal))
        }
        next.sort { lhs, rhs in
            if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        cursors = next
        epoch &+= 1
    }

    private func syncLocalCursor() {
        let (cx, cy) = term.cursor()
        if let i = cursors.firstIndex(where: { $0.isLocal }) {
            if cursors[i].col != cx || cursors[i].row != cy {
                cursors[i].col = cx
                cursors[i].row = cy
                epoch &+= 1
            }
        }
    }

    private func gridPosition(forOffset offset: Int,
                              anchorCol: UInt16,
                              anchorRow: UInt16) -> (col: UInt16, row: UInt16)
    {
        let cols = max(Int(self.cols), 1)
        let start = Int(anchorRow) * cols + Int(anchorCol)
        let linear = start + max(0, offset)
        let maxCell = max(Int(self.rows) * cols - 1, 0)
        let clamped = min(linear, maxCell)
        return (UInt16(clamped % cols), UInt16(clamped / cols))
    }

    private func linearIndex(forOffset offset: Int,
                             anchorCol: UInt16,
                             anchorRow: UInt16) -> Int?
    {
        let pos = gridPosition(
            forOffset: offset,
            anchorCol: anchorCol,
            anchorRow: anchorRow)
        return linearIndex(col: pos.col, row: pos.row)
    }

    private func linearIndex(col: UInt16, row: UInt16) -> Int? {
        let cols = Int(self.cols)
        let rows = Int(self.rows)
        guard cols > 0, rows > 0 else { return nil }
        let x = Int(col)
        let y = Int(row)
        guard x >= 0, x < cols, y >= 0, y < rows else { return nil }
        return y * cols + x
    }

    private func blankCell(from base: ct_cell) -> ct_cell {
        var cell = base
        cell.codepoint = 0x20
        cell.width = 1
        cell.attrs = 0
        cell.fg = readableOverlayForeground(
            preferred: base.fg,
            on: base.bg)
        return cell
    }

    private func readableOverlayForeground(preferred: UInt32, on background: UInt32) -> UInt32 {
        if contrastRatio(between: preferred, and: background) >= 4.5 {
            return preferred
        }
        return relativeLuminance(of: background) < 0.25 ? 0xF5F7FA : 0x111111
    }

    private func contrastRatio(between lhs: UInt32, and rhs: UInt32) -> Double {
        let l1 = relativeLuminance(of: lhs)
        let l2 = relativeLuminance(of: rhs)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(of packed: UInt32) -> Double {
        let r = linearizeComponent((packed >> 16) & 0xFF)
        let g = linearizeComponent((packed >> 8) & 0xFF)
        let b = linearizeComponent(packed & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func linearizeComponent(_ component: UInt32) -> Double {
        let normalized = Double(component) / 255.0
        if normalized <= 0.04045 {
            return normalized / 12.92
        }
        return pow((normalized + 0.055) / 1.055, 2.4)
    }
}
