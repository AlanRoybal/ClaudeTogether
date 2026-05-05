import SwiftUI
import AppKit
import Metal
import MetalKit
import Carbon.HIToolbox

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
    private var lastPropagatedGridSize: (cols: UInt16, rows: UInt16)?
    /// When true, keystrokes are dropped (peer in raw mode: creator-only input).
    var inputEnabled: Bool = true
    /// Tracks the user-visible "Mouse mode" toggle in the sidebar. When false,
    /// every mouse event falls through to default NSView behavior (focus on
    /// click, no PTY traffic) regardless of what the running app has DECSET.
    var mouseModeEnabled: Bool = false {
        didSet { refreshTrackingArea() }
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

    // MARK: selection
    private var selectionAnchor: (col: Int, row: Int)? = nil
    private var selectionHead: (col: Int, row: Int)? = nil

    init?(grid: GridModel,
          onKey: @escaping ([UInt8]) -> Void,
          onResize: @escaping (UInt16, UInt16) -> Void,
          onMouseCell: @escaping (UInt16, UInt16) -> Bool = { _, _ in false },
          pointSize: CGFloat = 13)
    {
        let view = MTKView(frame: .zero)
        self.mtkView = view
        self.grid = grid
        guard let renderer = TerminalRenderer(view: view, pointSize: pointSize) else {
            return nil
        }
        self.renderer = renderer
        self.onKey = onKey
        self.onResize = onResize
        self.onMouseCell = onMouseCell
        super.init(frame: .zero)

        renderer.grid = grid

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
        // immediately.
        if let size = currentAuthoritativeGridSize() {
            grid.resize(cols: size.cols, rows: size.rows, preserveTop: true)
        } else {
            grid.resize(cols: renderer.cols, rows: renderer.rows, preserveTop: true)
        }
    }

    func updateHandlers(onKey: @escaping ([UInt8]) -> Void,
                        onResize: @escaping (UInt16, UInt16) -> Void,
                        onMouseCell: @escaping (UInt16, UInt16) -> Bool)
    {
        self.onKey = onKey
        self.onResize = onResize
        self.onMouseCell = onMouseCell
    }

    /// Rebuilds the renderer's glyph atlas if the requested point size has
    /// changed. Triggers an immediate grid re-measure so PTY and view stay
    /// in sync.
    func updatePointSize(_ pointSize: CGFloat) {
        renderer.setPointSize(pointSize)
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
                    onKey(Array(sanitized.utf8))
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
        guard term.x10Mouse || term.dragMouse || term.anyMotionMouse else {
            return false
        }
        return term.sgrMouse
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if shouldReportMouse {
            clearSelection()
            reportClick(event: event, button: SGRButton.left, pressed: true)
            return
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
        guard shouldReportMouse else {
            super.mouseMoved(with: event)
            return
        }
        guard grid.term.anyMotionMouse else { return }
        reportMotion(event: event, button: 3)
    }

    override func scrollWheel(with event: NSEvent) {
        guard shouldReportMouse else {
            super.scrollWheel(with: event)
            return
        }
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
        guard let a = selectionAnchor, let h = selectionHead else { return nil }
        let startsBefore = a.row < h.row || (a.row == h.row && a.col <= h.col)
        let start = startsBefore ? a : h
        let end   = startsBefore ? h : a
        if start.col == end.col && start.row == end.row { return nil }

        let snap = grid.snapshot()
        let cols = Int(grid.cols)
        let rows = Int(grid.rows)
        guard cols > 0, rows > 0, snap.count >= cols * rows else { return nil }

        var result = ""
        for r in start.row...end.row {
            let colStart = r == start.row ? start.col : 0
            let colEnd   = r == end.row   ? end.col   : cols - 1
            var line = ""
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
            if r != end.row {
                while let last = line.last, last == " " { line.removeLast() }
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
        case kVK_Return:     return [0x0D]
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
        guard let size = currentLayoutDrawableSize() else { return nil }
        let cellWidth = max(1, renderer.atlas.cellWidthPx)
        let cellHeight = max(1, renderer.atlas.cellHeightPx)
        let cols = max(1, Int(size.width) / cellWidth)
        let rows = max(1, Int(size.height) / cellHeight)
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
        if let size = currentLayoutDrawableSize() {
            return size
        }
        let drawableSize = mtkView.drawableSize
        if drawableSize.width > 0, drawableSize.height > 0 {
            return drawableSize
        }
        return nil
    }
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
    let inputEnabled: Bool
    let isActive: Bool
    let fontSize: CGFloat
    /// Master switch for SGR mouse-reporting (the "Mouse mode" sidebar
    /// toggle). When false, mouse events fall through to default NSView
    /// behavior even if the running app has DECSET 1000/1002/1003.
    let mouseModeEnabled: Bool

    init(grid: GridModel,
         onKey: @escaping ([UInt8]) -> Void,
         onResize: @escaping (UInt16, UInt16) -> Void = { _, _ in },
         onMouseCell: @escaping (UInt16, UInt16) -> Bool = { _, _ in false },
         inputEnabled: Bool = true,
         isActive: Bool = true,
         fontSize: CGFloat = 13,
         mouseModeEnabled: Bool = false)
    {
        self.grid = grid
        self.onKey = onKey
        self.onResize = onResize
        self.onMouseCell = onMouseCell
        self.inputEnabled = inputEnabled
        self.isActive = isActive
        self.fontSize = fontSize
        self.mouseModeEnabled = mouseModeEnabled
    }

    func makeNSView(context: Context) -> MetalTerminalNSView {
        guard let v = MetalTerminalNSView(
            grid: grid,
            onKey: onKey,
            onResize: onResize,
            onMouseCell: onMouseCell,
            pointSize: fontSize)
        else {
            NSLog("MetalTerminalNSView init failed — Metal unavailable")
            return MetalTerminalNSView(
                grid: grid,
                onKey: { _ in },
                onResize: { _, _ in },
                onMouseCell: { _, _ in false },
                pointSize: fontSize)!
        }
        v.inputEnabled = inputEnabled
        v.mtkView.isPaused = !isActive
        v.mouseModeEnabled = mouseModeEnabled
        return v
    }

    func updateNSView(_ nsView: MetalTerminalNSView, context: Context) {
        nsView.updateGrid(grid)
        nsView.updateHandlers(
            onKey: onKey,
            onResize: onResize,
            onMouseCell: onMouseCell)
        nsView.inputEnabled = inputEnabled
        nsView.updatePointSize(fontSize)
        nsView.mtkView.isPaused = !isActive
        nsView.mouseModeEnabled = mouseModeEnabled
        nsView.refreshTrackingArea()
    }

    static func dismantleNSView(_ nsView: MetalTerminalNSView, coordinator: ()) {
        nsView.mtkView.delegate = nil
        nsView.mtkView.isPaused = true
    }
}
