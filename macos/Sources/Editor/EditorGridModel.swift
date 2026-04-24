import Foundation
import AppKit
import Combine

struct EditorCell {
    var codepoint: UInt32
    var fg: UInt32
    var bg: UInt32
}

struct UserSelection: Equatable {
    var row: UInt16
    var startCol: UInt16
    var endCol: UInt16
    var color: UInt32
}

/// Projects the collaborative document into a wrapped fixed-width grid.
/// The renderer only reads this model; all document mutations stay in
/// `EditorController`.
@MainActor
final class EditorGridModel: ObservableObject {
    private enum Theme {
        static let background: UInt32 = 0x141821
        static let foreground: UInt32 = 0xE8ECF3
    }

    let controller: EditorController
    let localCursorID = UUID()

    @Published private(set) var epoch: UInt64 = 0
    @Published private(set) var cursors: [UserCursor] = []
    @Published private(set) var selections: [UserSelection] = []
    @Published private(set) var scrollRow: Int = 0

    private(set) var cols: UInt16 = 80
    private(set) var rows: UInt16 = 24
    private(set) var cells: [EditorCell] = []

    private var offsetPositions: [(row: Int, col: Int)] = [(0, 0)]
    private var totalRows: Int = 1
    private var cancellables = Set<AnyCancellable>()

    init(controller: EditorController) {
        self.controller = controller
        self.cells = Self.blankCells(
            cols: Int(cols),
            rows: Int(rows),
            fg: Theme.foreground,
            bg: Theme.background)

        controller.state.$epoch
            .sink { [weak self] _ in
                guard let self else { return }
                self.rebuild(preserveScroll: false)
            }
            .store(in: &cancellables)

        rebuild(preserveScroll: false)
    }

    var state: EditorState { controller.state }

    func resize(cols: UInt16, rows: UInt16) {
        let newCols = max(1, cols)
        let newRows = max(1, rows)
        guard newCols != self.cols || newRows != self.rows else { return }
        self.cols = newCols
        self.rows = newRows
        rebuild(preserveScroll: false)
    }

    func scroll(byRows delta: Int) {
        guard delta != 0 else { return }
        let maxScroll = max(0, totalRows - Int(rows))
        let next = min(max(0, scrollRow + delta), maxScroll)
        guard next != scrollRow else { return }
        scrollRow = next
        rebuild(preserveScroll: true)
    }

    private func rebuild(preserveScroll: Bool) {
        let scalarView = Array(state.text.unicodeScalars)
        let colCount = max(Int(cols), 1)
        let rowCount = max(Int(rows), 1)
        let previousScrollRow = scrollRow

        var positions: [(row: Int, col: Int)] = []
        positions.reserveCapacity(scalarView.count + 1)
        positions.append((0, 0))

        var nextCells = Self.blankCells(
            cols: colCount,
            rows: rowCount,
            fg: Theme.foreground,
            bg: Theme.background)

        var row = 0
        var col = 0

        for scalar in scalarView {
            if scalar == "\n" {
                row += 1
                col = 0
                positions.append((row, col))
                continue
            }

            if col >= colCount {
                row += 1
                col = 0
            }

            if row >= scrollRow, row < scrollRow + rowCount {
                let visibleRow = row - scrollRow
                let index = visibleRow * colCount + col
                if index >= 0, index < nextCells.count {
                    nextCells[index].codepoint = scalar.value
                }
            }

            col += 1
            if col >= colCount {
                row += 1
                col = 0
            }
            positions.append((row, col))
        }

        offsetPositions = positions
        totalRows = max(1, row + 1)

        if !preserveScroll {
            ensureLocalCaretVisible()
        } else {
            let maxScroll = max(0, totalRows - rowCount)
            scrollRow = min(max(0, scrollRow), maxScroll)
        }

        // Re-render cells after a scroll adjustment caused by caret-follow.
        if !preserveScroll && scrollRow != previousScrollRow {
            nextCells = Self.blankCells(
                cols: colCount,
                rows: rowCount,
                fg: Theme.foreground,
                bg: Theme.background)
            row = 0
            col = 0
            for scalar in scalarView {
                if scalar == "\n" {
                    row += 1
                    col = 0
                    continue
                }
                if col >= colCount {
                    row += 1
                    col = 0
                }
                if row >= scrollRow, row < scrollRow + rowCount {
                    let visibleRow = row - scrollRow
                    let index = visibleRow * colCount + col
                    if index >= 0, index < nextCells.count {
                        nextCells[index].codepoint = scalar.value
                    }
                }
                col += 1
                if col >= colCount {
                    row += 1
                    col = 0
                }
            }
        }

        cells = nextCells
        selections = buildSelections()
        cursors = buildCursors()
        epoch &+= 1
    }

    private func ensureLocalCaretVisible() {
        let caret = positionForOffset(state.localCaret)
        let rowCount = max(Int(rows), 1)
        if caret.row < scrollRow {
            scrollRow = caret.row
        } else if caret.row >= scrollRow + rowCount {
            scrollRow = max(0, caret.row - rowCount + 1)
        }
        let maxScroll = max(0, totalRows - rowCount)
        scrollRow = min(max(0, scrollRow), maxScroll)
    }

    private func buildCursors() -> [UserCursor] {
        var next: [UserCursor] = []

        if let local = visibleCursor(
            id: localCursorID,
            offset: state.localCaret,
            color: packed(state.localCursorColor),
            isLocal: true)
        {
            next.append(local)
        }

        for (identity, cursor) in state.remoteCursors.sorted(by: {
            $0.key.uuidValue.uuidString < $1.key.uuidValue.uuidString
        }) {
            let head = controller.visibleOffset(for: cursor.anchor)
            guard let remote = visibleCursor(
                id: identity.uuidValue,
                offset: head,
                color: packed(cursor.color),
                isLocal: false)
            else {
                continue
            }
            next.append(remote)
        }

        return next
    }

    private func buildSelections() -> [UserSelection] {
        var bands: [UserSelection] = []

        if let anchor = state.localSelectionAnchor {
            bands.append(contentsOf: bandsForSelection(
                anchor: anchor,
                head: state.localCaret,
                color: 0x6CA6FF))
        }

        for (_, cursor) in state.remoteCursors {
            guard let selectionAnchor = cursor.selectionAnchor else { continue }
            let anchor = controller.visibleOffset(for: selectionAnchor)
            let head = controller.visibleOffset(for: cursor.anchor)
            bands.append(contentsOf: bandsForSelection(
                anchor: anchor,
                head: head,
                color: packed(cursor.color)))
        }

        return bands
    }

    private func bandsForSelection(anchor: Int,
                                   head: Int,
                                   color: UInt32) -> [UserSelection]
    {
        let lo = min(anchor, head)
        let hi = max(anchor, head)
        guard hi > lo else { return [] }

        let start = positionForOffset(lo)
        let end = positionForOffset(hi)
        let maxCol = max(Int(cols), 1)

        var out: [UserSelection] = []
        if start.row == end.row {
            guard let band = visibleBand(
                row: start.row,
                startCol: start.col,
                endCol: max(start.col + 1, end.col),
                color: color)
            else {
                return []
            }
            out.append(band)
            return out
        }

        if let first = visibleBand(
            row: start.row,
            startCol: start.col,
            endCol: maxCol,
            color: color)
        {
            out.append(first)
        }

        if end.row > start.row + 1 {
            for row in (start.row + 1)..<end.row {
                if let middle = visibleBand(
                    row: row,
                    startCol: 0,
                    endCol: maxCol,
                    color: color)
                {
                    out.append(middle)
                }
            }
        }

        if let last = visibleBand(
            row: end.row,
            startCol: 0,
            endCol: max(1, end.col),
            color: color)
        {
            out.append(last)
        }

        return out
    }

    private func visibleBand(row: Int,
                             startCol: Int,
                             endCol: Int,
                             color: UInt32) -> UserSelection?
    {
        let visibleRow = row - scrollRow
        guard visibleRow >= 0, visibleRow < Int(rows) else { return nil }
        let clampedStart = min(max(0, startCol), Int(cols))
        let clampedEnd = min(max(clampedStart + 1, endCol), Int(cols))
        guard clampedEnd > clampedStart else { return nil }
        return UserSelection(
            row: UInt16(visibleRow),
            startCol: UInt16(clampedStart),
            endCol: UInt16(clampedEnd),
            color: color)
    }

    private func visibleCursor(id: UUID,
                               offset: Int,
                               color: UInt32,
                               isLocal: Bool) -> UserCursor?
    {
        let pos = positionForOffset(offset)
        let visibleRow = pos.row - scrollRow
        guard visibleRow >= 0, visibleRow < Int(rows) else { return nil }
        return UserCursor(
            id: id,
            col: UInt16(min(max(0, pos.col), Int(cols - 1))),
            row: UInt16(visibleRow),
            color: color,
            isLocal: isLocal)
    }

    private func positionForOffset(_ offset: Int) -> (row: Int, col: Int) {
        let clamped = min(max(0, offset), max(0, offsetPositions.count - 1))
        return offsetPositions[clamped]
    }

    private static func blankCells(cols: Int,
                                   rows: Int,
                                   fg: UInt32,
                                   bg: UInt32) -> [EditorCell]
    {
        Array(repeating: EditorCell(codepoint: 0x20, fg: fg, bg: bg),
              count: max(1, cols * rows))
    }

    private func packed(_ color: NSColor) -> UInt32 {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let r = UInt32(max(0, min(255, Int(rgb.redComponent * 255.0))))
        let g = UInt32(max(0, min(255, Int(rgb.greenComponent * 255.0))))
        let b = UInt32(max(0, min(255, Int(rgb.blueComponent * 255.0))))
        return (r << 16) | (g << 8) | b
    }
}
