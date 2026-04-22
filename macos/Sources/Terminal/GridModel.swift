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
    let term: TermCore
    let localCursorID = UUID()

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

    func feed(_ bytes: [UInt8]) {
        term.feed(bytes)
        syncLocalCursor()
    }

    func resize(cols: UInt16, rows: UInt16) {
        term.resize(cols: cols, rows: rows)
        syncLocalCursor()
    }

    func snapshot() -> UnsafeBufferPointer<ct_cell> {
        term.snapshot()
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
}
