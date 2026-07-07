import SwiftUI
import AppKit
import Metal
import MetalKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// NSView subclass: MTKView wrapper that owns the `TerminalRenderer` and
/// routes keystrokes through a caller-supplied closure. The grid is also
/// supplied externally so the same view can front either a local PTY (host)
/// or inbound PTY-output frames (peer viewer).
final class MetalTerminalNSView: NSView {
    let mtkView: MTKView
    let renderer: TerminalRenderer
    private(set) var grid: GridModel
    private var onKey: ([UInt8]) -> Void
    private var onResize: (UInt16, UInt16) -> Void
    private var onMouseCell: (UInt16, UInt16) -> Bool
    /// Called with the sanitized paste string instead of `onKey` when set.
    /// Lets the model own bracket-wrapping and safe-paste confirmation.
    var onPaste: ((String) -> Void)?
    /// Called when the user drops a file onto the terminal.
    var onFileDrop: ((URL) -> Void)?
    private var lastPropagatedGridSize: (cols: UInt16, rows: UInt16)?
    /// When true, keystrokes are dropped (peer in raw mode: creator-only input).
    var inputEnabled: Bool = true
    /// Tracks the user-visible "Mouse mode" toggle in the sidebar. When false,
    /// every mouse event falls through to default NSView behavior (focus on
    /// click, no PTY traffic) regardless of what the running app has DECSET.
    var mouseModeEnabled: Bool = false {
        didSet { refreshTrackingArea() }
    }
    var theme: TerminalTheme = .defaultDark {
        // Guarded: setTheme clears the contrast/background memo caches and
        // forces a re-encode, and SwiftUI re-assigns this every updateNSView.
        didSet { if theme != oldValue { renderer.setTheme(theme) } }
    }

    /// Bookkeeping for SGR mouse encoding.
    private var mouseTrackingArea: NSTrackingArea?
    private var lastMotionCol: Int = -1
    private var lastMotionRow: Int = -1
    private var lastMotionTime: CFTimeInterval = 0
    /// 30Hz cap on mouseMoved reporting (1003 fires every motion event,
    /// which can swamp the PTY at trackpad rates).
    private static let motionMinInterval: CFTimeInterval = 1.0 / 30.0
    /// Track whether the last reportable mouse position was inside the
    /// grid. We don't want to spam clamped (col=0,row=0) reports when the
    /// pointer leaves the cell area.
    private var lastMotionInside: Bool = false
    /// Last known mouse position in cell coords, used by flagsChanged to
    /// update the cursor when cmd is pressed/released without moving the mouse.
    private var lastHoverCell: (col: Int, row: Int) = (-1, -1)

    // MARK: selection
    private var selectionAnchor: (col: Int, row: Int)? = nil
    private var selectionHead: (col: Int, row: Int)? = nil

    init?(grid: GridModel,
          onKey: @escaping ([UInt8]) -> Void,
          onResize: @escaping (UInt16, UInt16) -> Void,
          onMouseCell: @escaping (UInt16, UInt16) -> Bool = { _, _ in false },
          fontName: String = "",
          pointSize: CGFloat = 13)
    {
        let view = MTKView(frame: .zero)
        self.mtkView = view
        self.grid = grid
        guard let renderer = TerminalRenderer(view: view, fontName: fontName, pointSize: pointSize) else {
            return nil
        }
        self.renderer = renderer
        self.onKey = onKey
        self.onResize = onResize
        self.onMouseCell = onMouseCell
        super.init(frame: .zero)

        renderer.grid = grid
        registerForDraggedTypes([.fileURL])

        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        renderer.onResize = { [weak self] cols, rows in
            guard let self = self else { return }
            // Remotely-sized grids (peer mirrors) keep the host's geometry;
            // the local window only changes how much of them is visible.
            guard !self.grid.remotelySized else { return }
            self.grid.resize(cols: cols, rows: rows, preserveTop: true)
            self.propagateResizeIfAuthoritative(cols: cols, rows: rows)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func updateGrid(_ grid: GridModel) {
        guard self.grid !== grid else { return }
        syncRendererGridSize()
        self.grid = grid
        renderer.grid = grid

        // A reused NSView does not get a fresh resize callback when the model
        // swaps grids, so bring the new grid up to the renderer's live size
        // immediately. Remotely-sized grids keep the host's geometry.
        if grid.remotelySized {
            return
        }
        if let size = currentAuthoritativeGridSize() {
            grid.resize(cols: size.cols, rows: size.rows, preserveTop: true)
        } else {
            grid.resize(cols: renderer.cols, rows: renderer.rows, preserveTop: true)
        }
    }

    func updateHandlers(onKey: @escaping ([UInt8]) -> Void,
                        onResize: @escaping (UInt16, UInt16) -> Void,
                        onMouseCell: @escaping (UInt16, UInt16) -> Bool,
                        onPaste: ((String) -> Void)? = nil,
                        onFileDrop: ((URL) -> Void)? = nil)
    {
        self.onKey = onKey
        self.onResize = onResize
        self.onMouseCell = onMouseCell
        self.onPaste = onPaste
        self.onFileDrop = onFileDrop
    }

    // MARK: drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard inputEnabled,
              sender.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard inputEnabled,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first else { return false }
        onFileDrop?(url)
        return true
    }

    /// Rebuilds the renderer's glyph atlas if the requested point size has
    /// changed. Triggers an immediate grid re-measure so PTY and view stay
    /// in sync.
    func updatePointSize(_ pointSize: CGFloat) {
        renderer.setPointSize(pointSize)
    }

    func updateFontName(_ name: String) {
        renderer.setFontName(name)
    }

    func updateLigaturesEnabled(_ on: Bool) {
        renderer.ligaturesEnabled = on
    }

    override var acceptsFirstResponder: Bool { true }

    // Absorb all hit-tests so the MTKView subview doesn't swallow mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        syncRendererGridSize()
        refreshTrackingArea()
    }

    override func layout() {
        super.layout()
        syncRendererGridSize()
        refreshTrackingArea()
    }

    // MARK: keyboard -> closure

    override func keyDown(with event: NSEvent) {
        if handleScrollbackKey(event) { return }
        // Any keystroke clears an active selection (matches standard terminal UX).
        if selectionAnchor != nil { clearSelection() }
        guard inputEnabled else {
            NSSound.beep()
            return
        }
        if let bytes = encodeKey(event) {
            onKey(bytes)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleScrollbackKey(event) { return true }
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "c":
            // Selection copy takes priority over the menu's full-terminal copy.
            if let text = selectedText() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return true
            }
            // Fall through to let the menu's ⌘C → menuCopy() handle it.
        case "v":
            guard inputEnabled else { NSSound.beep(); return true }
            if let s = NSPasteboard.general.string(forType: .string) {
                let sanitized = TerminalPasteSanitizer.sanitize(s)
                if !sanitized.isEmpty {
                    if let onPaste {
                        onPaste(sanitized)
                    } else {
                        onKey(Array(sanitized.utf8))
                    }
                }
                return true
            }
        default: break
        }
        switch Int(event.keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_Delete:
            guard inputEnabled else { NSSound.beep(); return true }
            if let bytes = encodeKey(event) {
                onKey(bytes)
                return true
            }
        default:
            break
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: mouse -> terminal / selection

    private enum SGRButton {
        static let left: Int = 0
        static let middle: Int = 1
        static let right: Int = 2
        static let scrollUp: Int = 64
        static let scrollDown: Int = 65
        static let motionFlag: Int = 32
        static let shiftFlag: Int = 4
        static let altFlag: Int = 8
        static let ctrlFlag: Int = 16
    }

    private var shouldReportMouse: Bool {
        guard mouseModeEnabled else { return false }
        let term = grid.term
        return term.x10Mouse || term.dragMouse || term.anyMotionMouse
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if shouldReportMouse {
            clearSelection()
            reportClick(event: event, button: SGRButton.left, pressed: true)
            return
        }
        // OSC 8: cmd+click opens the hyperlink under the cursor. Use the
        // bounds-checked cell lookup so a click in the reserved corner inset
        // or past the right edge doesn't clamp onto — and open — the last
        // cell's link.
        if event.modifierFlags.contains(.command) {
            let cell = gridCell(for: event)
            if cell.inside,
               let url = grid.term.cellUrl(col: UInt16(cell.col), row: UInt16(cell.row)) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if reportSharedInputMouse(event: event) {
            clearSelection()
            return
        }
        let loc = convert(event.locationInWindow, from: nil)
        selectionAnchor = cellAt(point: loc)
        selectionHead = selectionAnchor
        renderer.selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        if shouldReportMouse {
            guard grid.term.dragMouse || grid.term.anyMotionMouse else { return }
            reportMotion(event: event, button: SGRButton.left)
            return
        }
        if reportSharedInputMouse(event: event) {
            clearSelection()
            return
        }
        let loc = convert(event.locationInWindow, from: nil)
        selectionHead = cellAt(point: loc)
        updateRendererSelection()
    }

    override func mouseUp(with event: NSEvent) {
        if shouldReportMouse {
            reportClick(event: event, button: SGRButton.left, pressed: false)
            return
        }
        guard let a = selectionAnchor, let h = selectionHead else { return }
        if a.col == h.col && a.row == h.row { clearSelection() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard shouldReportMouse else {
            super.rightMouseDown(with: event)
            return
        }
        reportClick(event: event, button: SGRButton.right, pressed: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard shouldReportMouse else {
            super.rightMouseUp(with: event)
            return
        }
        reportClick(event: event, button: SGRButton.right, pressed: false)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard shouldReportMouse else {
            super.otherMouseDown(with: event)
            return
        }
        reportClick(event: event, button: SGRButton.middle, pressed: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard shouldReportMouse else {
            super.otherMouseUp(with: event)
            return
        }
        reportClick(event: event, button: SGRButton.middle, pressed: false)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard shouldReportMouse else {
            super.rightMouseDragged(with: event)
            return
        }
        guard grid.term.dragMouse || grid.term.anyMotionMouse else { return }
        reportMotion(event: event, button: SGRButton.right)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard shouldReportMouse else {
            super.otherMouseDragged(with: event)
            return
        }
        guard grid.term.dragMouse || grid.term.anyMotionMouse else { return }
        reportMotion(event: event, button: SGRButton.middle)
    }

    override func mouseMoved(with event: NSEvent) {
        let cell = gridCell(for: event)
        lastHoverCell = (cell.col, cell.row)
        updateLinkCursor(col: cell.col, row: cell.row,
                         flags: event.modifierFlags, inside: cell.inside)
        guard shouldReportMouse else {
            super.mouseMoved(with: event)
            return
        }
        guard grid.term.anyMotionMouse else { return }
        reportMotion(event: event, button: 3)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // The OSC 8 link underline is gated on the live Cmd state, which is not
        // a grid mutation — force a redraw so it tracks the modifier in lockstep
        // with the hover cursor instead of waiting for the next unrelated frame.
        renderer.requestRedraw()
        let c = lastHoverCell
        guard c.col >= 0 else { return }
        updateLinkCursor(col: c.col, row: c.row,
                         flags: event.modifierFlags, inside: true)
    }

    private func updateLinkCursor(col: Int, row: Int,
                                  flags: NSEvent.ModifierFlags, inside: Bool)
    {
        guard inside, flags.contains(.command), !shouldReportMouse else {
            NSCursor.iBeam.set()
            return
        }
        if grid.term.cellUrl(col: UInt16(col), row: UInt16(row)) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if shouldReportMouse {
            let dy = event.scrollingDeltaY
            guard abs(dy) >= 0.1 else { return }
            let cell = gridCell(for: event)
            emitSGR(
                button: dy > 0 ? SGRButton.scrollUp : SGRButton.scrollDown,
                col: cell.col,
                row: cell.row,
                pressed: true,
                motion: false,
                flags: event.modifierFlags)
            return
        }
        let dy = event.scrollingDeltaY
        guard abs(dy) >= 0.1 else { return }
        let magnitude = max(1, Int(abs(dy) / 12.0))
        if grid.scroll(byRows: dy > 0 ? magnitude : -magnitude) {
            clearSelection()
            return
        }
        // Alt-screen TUIs (claude, vim, htop) own their scroll history — the
        // grid has nothing to scroll, so a wheel event would otherwise be a
        // dead no-op. Route it to the app when it has asked for mouse
        // reporting, even with the sidebar Mouse Mode toggle off: that toggle
        // exists to keep clicks local for text selection, and the wheel plays
        // no part in selecting.
        let term = grid.term
        if term.isUsingAlternateScreen,
           term.x10Mouse || term.dragMouse || term.anyMotionMouse
        {
            let cell = gridCell(for: event)
            emitSGR(
                button: dy > 0 ? SGRButton.scrollUp : SGRButton.scrollDown,
                col: cell.col,
                row: cell.row,
                pressed: true,
                motion: false,
                flags: event.modifierFlags)
        }
    }

    private func handleScrollbackKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.shift) else { return false }
        let page = max(1, Int(renderer.rows) - 1)
        switch Int(event.keyCode) {
        case kVK_PageUp:
            return grid.scroll(byRows: page)
        case kVK_PageDown:
            return grid.scroll(byRows: -page)
        case kVK_Home:
            return grid.scroll(byRows: Int.max / 4)
        case kVK_End:
            grid.scrollToBottom()
            return true
        default:
            return false
        }
    }

    private func reportSharedInputMouse(event: NSEvent) -> Bool {
        guard mouseModeEnabled else { return false }
        let cell = gridCell(for: event)
        guard cell.inside else { return false }
        return onMouseCell(UInt16(cell.col), UInt16(cell.row))
    }

    private func reportClick(event: NSEvent, button: Int, pressed: Bool) {
        let cell = gridCell(for: event)
        emitSGR(
            button: button,
            col: cell.col,
            row: cell.row,
            pressed: pressed,
            motion: false,
            flags: event.modifierFlags)
        if pressed {
            lastMotionCol = cell.col
            lastMotionRow = cell.row
            lastMotionInside = cell.inside
        }
    }

    private func reportMotion(event: NSEvent, button: Int) {
        let cell = gridCell(for: event)
        if cell.inside,
           cell.col == lastMotionCol,
           cell.row == lastMotionRow,
           lastMotionInside
        {
            return
        }
        if !cell.inside, !lastMotionInside { return }

        let now = CACurrentMediaTime()
        guard now - lastMotionTime >= Self.motionMinInterval else { return }
        lastMotionTime = now

        emitSGR(
            button: button,
            col: cell.col,
            row: cell.row,
            pressed: true,
            motion: true,
            flags: event.modifierFlags)
        lastMotionCol = cell.col
        lastMotionRow = cell.row
        lastMotionInside = cell.inside
    }

    private func emitSGR(button: Int,
                         col: Int,
                         row: Int,
                         pressed: Bool,
                         motion: Bool,
                         flags: NSEvent.ModifierFlags)
    {
        let cb = button | sgrModifierBits(flags) | (motion ? SGRButton.motionFlag : 0)
        guard grid.term.sgrMouse else {
            // 1015 urxvt takes precedence over legacy X10 when the app chose
            // it: its parser expects decimal params, so X10's raw +32 bytes
            // would desync it.
            if grid.term.urxvtMouse {
                emitUrxvtMouse(cb: cb, col: col, row: row, pressed: pressed)
            } else {
                emitLegacyMouse(cb: cb, col: col, row: row, pressed: pressed)
            }
            return
        }
        let terminator: UInt8 = pressed ? 0x4D : 0x6D
        var bytes: [UInt8] = [0x1B, 0x5B, 0x3C]
        bytes.append(contentsOf: Array(String(cb).utf8))
        bytes.append(0x3B)
        bytes.append(contentsOf: Array(String(col + 1).utf8))
        bytes.append(0x3B)
        bytes.append(contentsOf: Array(String(row + 1).utf8))
        bytes.append(terminator)
        onKey(bytes)
    }

    /// Legacy X10/normal tracking encoding (DECSET 1000/1002/1003 without
    /// 1006): CSI M Cb Cx Cy, each payload byte offset by 32. Releases
    /// collapse the button bits to 3; coordinates saturate at 223 because the
    /// encoding can't express more than 255 - 32.
    private func emitLegacyMouse(cb: Int, col: Int, row: Int, pressed: Bool) {
        let cbByte = pressed ? cb : ((cb & ~0b11) | 3)
        let bytes: [UInt8] = [
            0x1B, 0x5B, 0x4D,
            UInt8(32 + min(cbByte, 223)),
            UInt8(32 + min(col + 1, 223)),
            UInt8(32 + min(row + 1, 223)),
        ]
        onKey(bytes)
    }

    /// urxvt encoding (DECSET 1015): CSI Cb ; Cx ; Cy M — like X10 but the
    /// three values are decimal text (Cb still carries the +32 button offset),
    /// so coordinates aren't capped at 223. Releases collapse to button 3.
    private func emitUrxvtMouse(cb: Int, col: Int, row: Int, pressed: Bool) {
        let cbByte = (pressed ? cb : ((cb & ~0b11) | 3)) + 32
        var bytes: [UInt8] = [0x1B, 0x5B]
        bytes.append(contentsOf: Array(String(cbByte).utf8))
        bytes.append(0x3B)
        bytes.append(contentsOf: Array(String(col + 1).utf8))
        bytes.append(0x3B)
        bytes.append(contentsOf: Array(String(row + 1).utf8))
        bytes.append(0x4D)
        onKey(bytes)
    }

    private func sgrModifierBits(_ flags: NSEvent.ModifierFlags) -> Int {
        var b = 0
        if flags.contains(.shift) { b |= SGRButton.shiftFlag }
        if flags.contains(.option) { b |= SGRButton.altFlag }
        if flags.contains(.control) { b |= SGRButton.ctrlFlag }
        return b
    }

    // MARK: selection helpers

    private func cellAt(point: NSPoint) -> (col: Int, row: Int) {
        let scale = window?.backingScaleFactor ?? 1.0
        let cellWPt = CGFloat(renderer.atlas.cellWidthPx) / scale
        let cellHPt = CGFloat(renderer.atlas.cellHeightPx) / scale
        // NSView y=0 is at the bottom; terminal row 0 is at the top.
        let flippedY = bounds.height - point.y
        let col = Int(point.x / cellWPt)
        let row = Int(flippedY / cellHPt)
        return (
            max(0, min(col, Int(renderer.cols) - 1)),
            max(0, min(row, Int(renderer.rows) - 1))
        )
    }

    private func gridCell(for event: NSEvent) -> (col: Int, row: Int, inside: Bool) {
        let p = convert(event.locationInWindow, from: nil)
        let cell = renderer.cellSize
        let cw = max(cell.width, 0.5)
        let ch = max(cell.height, 0.5)
        let yTopDown = bounds.height - p.y
        let rawCol = Int(floor(p.x / cw))
        let rawRow = Int(floor(yTopDown / ch))
        let cols = Int(renderer.cols)
        let rows = Int(renderer.rows)
        let inside = rawCol >= 0 && rawCol < cols && rawRow >= 0 && rawRow < rows
        let col = min(max(rawCol, 0), max(cols - 1, 0))
        let row = min(max(rawRow, 0), max(rows - 1, 0))
        return (col, row, inside)
    }

    private func clearSelection() {
        selectionAnchor = nil
        selectionHead = nil
        renderer.selection = nil
    }

    private func updateRendererSelection() {
        guard let a = selectionAnchor, let h = selectionHead else {
            renderer.selection = nil
            return
        }
        let startsBefore = a.row < h.row || (a.row == h.row && a.col <= h.col)
        renderer.selection = startsBefore
            ? (start: a, end: h)
            : (start: h, end: a)
    }

    /// Returns the text covered by the current selection, or nil if nothing
    /// is selected. Uses the grid snapshot so it reads live terminal content.
    private func selectedText() -> String? {
        guard var a = selectionAnchor, var h = selectionHead else { return nil }

        let snap = grid.snapshot()
        let cols = Int(grid.cols)
        let rows = Int(grid.rows)
        guard cols > 0, rows > 0, snap.count >= cols * rows else { return nil }

        // The selection endpoints were clamped to the grid size at mouse-down;
        // if the grid has shrunk since (resize, font change) they can now lie
        // outside it — re-clamp or the ranges below trap.
        a = (col: min(a.col, cols - 1), row: min(a.row, rows - 1))
        h = (col: min(h.col, cols - 1), row: min(h.row, rows - 1))

        let startsBefore = a.row < h.row || (a.row == h.row && a.col <= h.col)
        let start = startsBefore ? a : h
        let end   = startsBefore ? h : a
        if start.col == end.col && start.row == end.row { return nil }

        var result = ""
        for r in start.row...end.row {
            let colStart = r == start.row ? start.col : 0
            let colEnd   = r == end.row   ? end.col   : cols - 1
            var line = ""
            guard colStart <= colEnd else {
                if r != end.row { result += "\n" }
                continue
            }
            for c in colStart...colEnd {
                guard c < cols && r < rows else { break }
                let cell = snap[r * cols + c]
                if cell.width == 0 { continue }
                let cp = cell.codepoint
                if cp == 0 {
                    line.append(" ")
                } else if let scalar = UnicodeScalar(cp) {
                    line.append(Character(scalar))
                } else {
                    line.append(" ")
                }
            }
            // Trim trailing spaces on every line (including the last) so
            // copied text never carries cell-padding whitespace.
            while let last = line.last, last == " " { line.removeLast() }
            if r != end.row {
                result += line + "\n"
            } else {
                result += line
            }
        }
        return result.isEmpty ? nil : result
    }

    private func encodeKey(_ event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags
        let keyCode = Int(event.keyCode)
        let command = flags.contains(.command)
        let option = flags.contains(.option)

        switch keyCode {
        case kVK_UpArrow:
            return Array("\u{1B}[A".utf8)
        case kVK_DownArrow:
            return Array("\u{1B}[B".utf8)
        case kVK_RightArrow:
            if command { return [0x05] } // Ctrl-E: end of line.
            if option { return Array("\u{1B}f".utf8) } // Meta-f: next word.
            return Array("\u{1B}[C".utf8)
        case kVK_LeftArrow:
            if command { return [0x01] } // Ctrl-A: beginning of line.
            if option { return Array("\u{1B}b".utf8) } // Meta-b: previous word.
            return Array("\u{1B}[D".utf8)
        case kVK_Return:
            // NSEvent reports Shift+Return as a plain \r, so encode it as the
            // xterm CSI-u sequence to keep it distinguishable downstream. The
            // shared input line turns it into a newline insert; every raw PTY
            // path normalizes it back to \r (see TerminalModel.handleKey).
            if flags.contains(.shift) { return TerminalKeySequences.shiftReturn }
            return [0x0D]
        case kVK_Tab:        return [0x09]
        case kVK_Delete:
            if command { return [0x15] } // Ctrl-U: delete to beginning.
            if option { return [0x1B, 0x7F] } // Meta-Backspace: delete word.
            return [0x7F] // Backspace
        case kVK_ForwardDelete: return Array("\u{1B}[3~".utf8)
        case kVK_Escape:     return [0x1B]
        case kVK_Home:       return Array("\u{1B}[H".utf8)
        case kVK_End:        return Array("\u{1B}[F".utf8)
        case kVK_PageUp:     return Array("\u{1B}[5~".utf8)
        case kVK_PageDown:   return Array("\u{1B}[6~".utf8)
        default: break
        }

        // Ctrl-<letter>: map to C0 control byte.
        if flags.contains(.control),
           let chars = event.charactersIgnoringModifiers,
           let first = chars.unicodeScalars.first,
           first.value >= 0x40 && first.value <= 0x7E
        {
            let b = UInt8(first.value) & 0x1F
            return [b]
        }

        // Alt-<char>: prefix ESC.
        if flags.contains(.option),
           let chars = event.characters, !chars.isEmpty
        {
            var out: [UInt8] = [0x1B]
            out.append(contentsOf: Array(chars.utf8))
            return out
        }

        if let chars = event.characters, !chars.isEmpty {
            return Array(chars.utf8)
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea()
    }

    func refreshTrackingArea() {
        if mouseModeEnabled {
            if let area = mouseTrackingArea, trackingAreas.contains(area) {
                return
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil)
            addTrackingArea(area)
            mouseTrackingArea = area
            window?.acceptsMouseMovedEvents = true
        } else if let area = mouseTrackingArea {
            removeTrackingArea(area)
            mouseTrackingArea = nil
        }
    }

    private func syncRendererGridSize() {
        guard let size = currentDrawableSizeForSync() else { return }
        renderer.recomputeGrid(for: size)
        propagateResizeIfAuthoritative(cols: renderer.cols, rows: renderer.rows)
    }

    private func propagateResizeIfAuthoritative(cols: UInt16, rows: UInt16) {
        guard let size = currentAuthoritativeGridSize() else { return }
        guard size.cols == cols && size.rows == rows else { return }
        if let last = lastPropagatedGridSize,
           last.cols == cols,
           last.rows == rows
        {
            return
        }
        lastPropagatedGridSize = (cols, rows)
        onResize(cols, rows)
    }

    private func currentAuthoritativeGridSize() -> (cols: UInt16, rows: UInt16)? {
        // Must use the same size source AND the same formula as
        // recomputeGrid so that authoritative rows == renderer.rows and
        // propagateResizeIfAuthoritative can fire.
        let drawableSize = mtkView.drawableSize
        let size: CGSize
        if drawableSize.width > 0, drawableSize.height > 0 {
            size = drawableSize
        } else if let layout = currentLayoutDrawableSize() {
            size = layout
        } else {
            return nil
        }
        let cellWidth = max(1, renderer.atlas.cellWidthPx)
        let cellHeight = max(1, renderer.atlas.cellHeightPx)
        let cols = max(1, Int(size.width) / cellWidth)
        let cornerInsetPx = Int(10.0 * renderer.atlas.scale)
        let rows = max(1, (Int(size.height) - cornerInsetPx) / cellHeight)
        return (
            cols: UInt16(min(Int(UInt16.max), cols)),
            rows: UInt16(min(Int(UInt16.max), rows))
        )
    }

    private func currentLayoutDrawableSize() -> CGSize? {
        guard window != nil, bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        let fallback = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale)
        guard fallback.width > 0, fallback.height > 0 else { return nil }
        return fallback
    }

    private func currentDrawableSizeForSync() -> CGSize? {
        // Prefer the Metal drawable size — it's what the render uniforms use,
        // so the row/col count stays consistent and cells never render outside
        // the viewport. Fall back to layout bounds before Metal sets up.
        let drawableSize = mtkView.drawableSize
        if drawableSize.width > 0, drawableSize.height > 0 {
            return drawableSize
        }
        return currentLayoutDrawableSize()
    }
}

enum TerminalKeySequences {
    /// xterm CSI-u (modifyOtherKeys) encoding of Shift+Return. Never sent to
    /// a PTY: it exists so the model can tell Shift+Enter apart from Enter,
    /// and is normalized back to \r on every raw-byte path.
    static let shiftReturn: [UInt8] = Array("\u{1B}[13;2u".utf8)
}

enum TerminalPasteSanitizer {
    private static let promptRegex = try! NSRegularExpression(
        pattern: #"^\S+@\S+(?:\s+.*?)?\s[%#]\s+"#)

    static func sanitize(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var strippedPrompt = false
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let result = stripPromptPrefixes(from: String(line))
                strippedPrompt = strippedPrompt || result.didStrip
                return result.text
            }

        var result = lines.joined(separator: "\n")
        if strippedPrompt {
            result = result.trimmingTrailingNewlines()
        }
        return result
    }

    private static func stripPromptPrefixes(from line: String) -> (text: String, didStrip: Bool) {
        var remaining = line
        var didStrip = false
        while let match = promptRegex.firstMatch(
            in: remaining,
            range: NSRange(remaining.startIndex..<remaining.endIndex, in: remaining)),
            match.range.location == 0,
            let range = Range(match.range, in: remaining)
        {
            remaining = String(remaining[range.upperBound...])
            didStrip = true
        }
        return (remaining, didStrip)
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var result = self
        while result.last == "\n" {
            result.removeLast()
        }
        return result
    }
}

/// SwiftUI bridge. Caller supplies the grid and closures; this view is
/// agnostic to whether the bytes come from a local PTY or a remote host.
struct MetalTerminalView: NSViewRepresentable {
    let grid: GridModel
    let onKey: ([UInt8]) -> Void
    let onResize: (UInt16, UInt16) -> Void
    let onMouseCell: (UInt16, UInt16) -> Bool
    let onPaste: ((String) -> Void)?
    let onFileDrop: ((URL) -> Void)?
    let inputEnabled: Bool
    let isActive: Bool
    let fontSize: CGFloat
    /// Master switch for SGR mouse-reporting (the "Mouse mode" sidebar
    /// toggle). When false, mouse events fall through to default NSView
    /// behavior even if the running app has DECSET 1000/1002/1003.
    let mouseModeEnabled: Bool
    let theme: TerminalTheme
    let fontName: String
    let ligaturesEnabled: Bool
    let searchMatches: [SearchMatch]
    let currentMatchIndex: Int?

    init(grid: GridModel,
         onKey: @escaping ([UInt8]) -> Void,
         onResize: @escaping (UInt16, UInt16) -> Void = { _, _ in },
         onMouseCell: @escaping (UInt16, UInt16) -> Bool = { _, _ in false },
         onPaste: ((String) -> Void)? = nil,
         onFileDrop: ((URL) -> Void)? = nil,
         inputEnabled: Bool = true,
         isActive: Bool = true,
         fontSize: CGFloat = 13,
         mouseModeEnabled: Bool = false,
         theme: TerminalTheme = .defaultDark,
         fontName: String = "",
         ligaturesEnabled: Bool = true,
         searchMatches: [SearchMatch] = [],
         currentMatchIndex: Int? = nil)
    {
        self.grid = grid
        self.onKey = onKey
        self.onResize = onResize
        self.onMouseCell = onMouseCell
        self.onPaste = onPaste
        self.onFileDrop = onFileDrop
        self.inputEnabled = inputEnabled
        self.isActive = isActive
        self.fontSize = fontSize
        self.mouseModeEnabled = mouseModeEnabled
        self.theme = theme
        self.fontName = fontName
        self.ligaturesEnabled = ligaturesEnabled
        self.searchMatches = searchMatches
        self.currentMatchIndex = currentMatchIndex
    }

    func makeNSView(context: Context) -> NSView {
        guard let v = MetalTerminalNSView(
            grid: grid,
            onKey: onKey,
            onResize: onResize,
            onMouseCell: onMouseCell,
            fontName: fontName,
            pointSize: fontSize)
        else {
            // Retrying the same failable init would fail for the same reason;
            // degrade to a plain label instead of crashing on a force-unwrap.
            NSLog("MetalTerminalNSView init failed — Metal unavailable")
            let placeholder = NSTextField(
                labelWithString: "Terminal rendering is unavailable (Metal could not be initialized).")
            placeholder.alignment = .center
            return placeholder
        }
        v.inputEnabled = inputEnabled
        v.onPaste = onPaste
        v.onFileDrop = onFileDrop
        v.mtkView.isPaused = !isActive
        v.mouseModeEnabled = mouseModeEnabled
        v.theme = theme
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let nsView = nsView as? MetalTerminalNSView else { return }
        nsView.updateGrid(grid)
        nsView.updateHandlers(
            onKey: onKey,
            onResize: onResize,
            onMouseCell: onMouseCell,
            onPaste: onPaste,
            onFileDrop: onFileDrop)
        nsView.inputEnabled = inputEnabled
        nsView.updatePointSize(fontSize)
        nsView.updateFontName(fontName)
        nsView.updateLigaturesEnabled(ligaturesEnabled)
        nsView.mtkView.isPaused = !isActive
        nsView.mouseModeEnabled = mouseModeEnabled
        nsView.refreshTrackingArea()
        nsView.theme = theme
        nsView.renderer.searchMatches = searchMatches
        nsView.renderer.currentMatchIndex = currentMatchIndex
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let nsView = nsView as? MetalTerminalNSView else { return }
        nsView.mtkView.delegate = nil
        nsView.mtkView.isPaused = true
    }
}
