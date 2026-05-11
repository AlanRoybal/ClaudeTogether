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
    private var peerTerminalCursors: [UUID: (col: UInt16, row: UInt16, color: UInt32)] = [:]

    /// Ordered list of cursors currently visible in the viewport.
    @Published private(set) var cursors: [UserCursor]
    /// Rows scrolled back from the live terminal bottom. 0 means the normal
    /// live viewport; larger values show older scrollback rows.
    @Published private(set) var scrollOffsetRows: Int = 0

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
        // Always follow new output: snap back to the live view so the terminal
        // auto-scrolls. Users who want to read history can scroll up manually;
        // the scroll-back indicator lets them return to the live view.
        scrollOffsetRows = 0
        if overlay == nil {
            syncTerminalCursors()
        } else {
            syncOverlayCursors()
        }
    }

    func resize(cols: UInt16, rows: UInt16, preserveTop: Bool = false) {
        term.resize(cols: cols, rows: rows, preserveTop: preserveTop)
        clampScrollOffset()
        if overlay == nil {
            syncTerminalCursors()
        } else {
            syncOverlayCursors()
        }
    }

    @discardableResult
    func scroll(byRows delta: Int) -> Bool {
        guard delta != 0, !term.isUsingAlternateScreen else { return false }
        let next = min(max(0, scrollOffsetRows + delta), maxScrollOffset)
        guard next != scrollOffsetRows else { return false }
        scrollOffsetRows = next
        if overlay == nil {
            syncTerminalCursors()
        } else {
            syncOverlayCursors()
        }
        epoch &+= 1
        return true
    }

    func scrollToBottom() {
        guard scrollOffsetRows != 0 else { return }
        scrollOffsetRows = 0
        if overlay == nil {
            syncTerminalCursors()
        } else {
            syncOverlayCursors()
        }
        epoch &+= 1
    }

    func snapshot() -> UnsafeBufferPointer<ct_cell> {
        let base = term.snapshot()
        let scrollOffset = effectiveScrollOffset()
        guard scrollOffset > 0 || overlay != nil else { return base }

        if overlaySnapshot.count != base.count {
            overlaySnapshot = [ct_cell](repeating: ct_cell(), count: base.count)
        }
        if scrollOffset > 0 {
            copyScrolledSnapshot(primary: base, offset: scrollOffset)
        } else {
            for i in 0..<base.count {
                overlaySnapshot[i] = base[i]
            }
        }

        guard let overlay else {
            return overlaySnapshot.withUnsafeBufferPointer { $0 }
        }

        let maxCursorOffset = overlay.cursors.map(\.offset).max() ?? 0
        let span = max(1, max(overlay.textScalars.count, maxCursorOffset + 1))
        var styleIndex: Int?
        for offset in 0..<span {
            if let idx = linearIndex(
                forOffset: offset,
                anchorCol: overlay.anchorCol,
                anchorRow: overlay.anchorRow)
            {
                styleIndex = idx
                break
            }
        }

        guard let styleIndex else {
            return overlaySnapshot.withUnsafeBufferPointer { $0 }
        }

        let styleCell = overlaySnapshot[styleIndex]
        let blank = blankCell(from: styleCell)

        for offset in 0..<span {
            guard let idx = linearIndex(
                forOffset: offset,
                anchorCol: overlay.anchorCol,
                anchorRow: overlay.anchorRow)
            else {
                continue
            }
            overlaySnapshot[idx] = blank
        }

        for (offset, scalar) in overlay.textScalars.enumerated() {
            guard let idx = linearIndex(
                forOffset: offset,
                anchorCol: overlay.anchorCol,
                anchorRow: overlay.anchorRow)
            else {
                continue
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
        syncTerminalCursors()
        epoch &+= 1
    }

    func inputOverlayOffset(atCol col: UInt16, row: UInt16) -> Int? {
        guard let overlay else { return nil }
        let cols = max(Int(self.cols), 1)
        guard let primaryRow = primaryRow(forVisibleRow: Int(row)) else {
            return nil
        }
        let start = Int(overlay.anchorRow) * cols + Int(overlay.anchorCol)
        let target = primaryRow * cols + Int(col)
        let end = start + overlay.textScalars.count
        guard target >= start else { return nil }
        guard target <= end || primaryRow == end / cols else { return nil }
        return min(max(0, target - start), overlay.textScalars.count)
    }

    /// Updates or inserts a peer cursor. Called by session code when a
    /// `CursorPos` frame arrives from a peer.
    func upsertPeerCursor(id: UUID, col: UInt16, row: UInt16, color: UInt32) {
        peerTerminalCursors[id] = (col: col, row: row, color: color)
        if overlay == nil {
            syncTerminalCursors()
        }
    }

    func removePeerCursor(id: UUID) {
        peerTerminalCursors.removeValue(forKey: id)
        cursors.removeAll { $0.id == id && !$0.isLocal }
        epoch &+= 1
    }

    private func syncOverlayCursors() {
        guard let overlay else {
            syncTerminalCursors()
            return
        }

        var next: [UserCursor] = []
        next.reserveCapacity(overlay.cursors.count)
        for cursor in overlay.cursors {
            guard let position = gridPosition(
                forOffset: cursor.offset,
                anchorCol: overlay.anchorCol,
                anchorRow: overlay.anchorRow)
            else {
                continue
            }
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

    private func syncTerminalCursors() {
        guard overlay == nil else {
            syncOverlayCursors()
            return
        }
        let (cx, cy) = term.cursor()
        var next: [UserCursor] = []
        if let row = visibleRow(forPrimaryRow: Int(cy)) {
            next.append(UserCursor(
                id: localCursorID,
                col: cx,
                row: UInt16(row),
                color: 0xFFFFFF,
                isLocal: true))
        }
        for (id, cursor) in peerTerminalCursors.sorted(by: {
            $0.key.uuidString < $1.key.uuidString
        }) {
            guard let row = visibleRow(forPrimaryRow: Int(cursor.row)) else {
                continue
            }
            next.append(UserCursor(
                id: id,
                col: cursor.col,
                row: UInt16(row),
                color: cursor.color,
                isLocal: false))
        }
        guard next != cursors else { return }
        cursors = next
        epoch &+= 1
    }

    private func gridPosition(forOffset offset: Int,
                              anchorCol: UInt16,
                              anchorRow: UInt16) -> (col: UInt16, row: UInt16)?
    {
        let cols = max(Int(self.cols), 1)
        let start = Int(anchorRow) * cols + Int(anchorCol)
        let linear = start + max(0, offset)
        let primaryRow = linear / cols
        guard let visibleRow = visibleRow(forPrimaryRow: primaryRow) else {
            return nil
        }
        return (UInt16(linear % cols), UInt16(visibleRow))
    }

    private func linearIndex(forOffset offset: Int,
                             anchorCol: UInt16,
                             anchorRow: UInt16) -> Int?
    {
        let pos = gridPosition(
            forOffset: offset,
            anchorCol: anchorCol,
            anchorRow: anchorRow)
        guard let pos else { return nil }
        return linearIndex(col: pos.col, row: pos.row)
    }

    private var maxScrollOffset: Int {
        term.isUsingAlternateScreen ? 0 : term.scrollbackLength
    }

    private func effectiveScrollOffset() -> Int {
        min(max(0, scrollOffsetRows), maxScrollOffset)
    }

    private func clampScrollOffset() {
        let clamped = effectiveScrollOffset()
        if clamped != scrollOffsetRows {
            scrollOffsetRows = clamped
        }
    }

    private func windowStartRow(scrollOffset: Int? = nil) -> Int {
        term.scrollbackLength - (scrollOffset ?? effectiveScrollOffset())
    }

    private func visibleRow(forPrimaryRow primaryRow: Int) -> Int? {
        let absoluteRow = term.scrollbackLength + primaryRow
        let visibleRow = absoluteRow - windowStartRow()
        guard visibleRow >= 0, visibleRow < Int(rows) else { return nil }
        return visibleRow
    }

    private func primaryRow(forVisibleRow visibleRow: Int) -> Int? {
        let absoluteRow = windowStartRow() + visibleRow
        let primaryRow = absoluteRow - term.scrollbackLength
        guard primaryRow >= 0, primaryRow < Int(rows) else { return nil }
        return primaryRow
    }

    private func copyScrolledSnapshot(primary: UnsafeBufferPointer<ct_cell>,
                                      offset: Int)
    {
        guard !overlaySnapshot.isEmpty else { return }
        let cols = max(Int(self.cols), 1)
        let rows = max(Int(self.rows), 1)
        let scrollbackLength = term.scrollbackLength
        let startRow = scrollbackLength - offset

        var visibleRow = 0
        if startRow < scrollbackLength {
            let scrollbackRows = min(rows, scrollbackLength - startRow)
            var scrollbackCells = [ct_cell](
                repeating: ct_cell(),
                count: scrollbackRows * cols)
            let copied = term.copyScrollback(
                startRow: startRow,
                rowCount: scrollbackRows,
                into: &scrollbackCells)
            let cellsToCopy = min(copied * cols, overlaySnapshot.count)
            if cellsToCopy > 0 {
                overlaySnapshot.replaceSubrange(
                    0..<cellsToCopy,
                    with: scrollbackCells.prefix(cellsToCopy))
            }
            visibleRow = copied
        }

        var primaryRow = max(0, startRow + visibleRow - scrollbackLength)
        while visibleRow < rows {
            let dstStart = visibleRow * cols
            let srcStart = primaryRow * cols
            guard dstStart < overlaySnapshot.count else { break }
            if srcStart + cols <= primary.count {
                overlaySnapshot.replaceSubrange(
                    dstStart..<(dstStart + cols),
                    with: primary[srcStart..<(srcStart + cols)])
            }
            visibleRow += 1
            primaryRow += 1
        }
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
