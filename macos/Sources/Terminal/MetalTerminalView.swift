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
    private let onKey: ([UInt8]) -> Void
    private let onResize: (UInt16, UInt16) -> Void
    /// When true, keystrokes are dropped (peer in raw mode: creator-only input).
    var inputEnabled: Bool = true
    /// Tracks the user-visible "Mouse mode" toggle in the sidebar. When false,
    /// every mouse event falls through to default NSView behavior (focus on
    /// click, no PTY traffic) regardless of what the running app has DECSET.
    var mouseModeEnabled: Bool = true {
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

    init?(grid: GridModel,
          onKey: @escaping ([UInt8]) -> Void,
          onResize: @escaping (UInt16, UInt16) -> Void)
    {
        let view = MTKView(frame: .zero)
        self.mtkView = view
        self.grid = grid
        guard let renderer = TerminalRenderer(view: view) else { return nil }
        self.renderer = renderer
        self.onKey = onKey
        self.onResize = onResize
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
            self.grid.resize(cols: cols, rows: rows)
            self.onResize(cols, rows)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: hit testing
    //
    // The MTKView covers our bounds and would otherwise swallow clicks. We
    // intercept hit testing so mouseDown lands on us regardless of mouse
    // mode — the actual "consume vs. fall through" decision lives inside
    // each event handler. Returning self also gives the window a clear
    // first-responder target on click without any extra makeFirstResponder
    // gymnastics.

    override func hitTest(_ point: NSPoint) -> NSView? {
        if bounds.contains(convert(point, from: superview)) {
            return self
        }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Allow a click to both focus the window and report through to the
        // PTY in one gesture (matters for terminals when the host window is
        // not yet key).
        return true
    }

    // We deliberately do NOT override `isFlipped`: the MTKView rendering
    // already runs in NDC space and we don't want to disturb it. Mouse
    // event Y is flipped to grid-row space inside `gridCell(for:)`.

    func updateGrid(_ grid: GridModel) {
        guard self.grid !== grid else { return }
        self.grid = grid
        renderer.grid = grid

        // A reused NSView does not get a fresh resize callback when the model
        // swaps grids, so bring the new grid up to the renderer's live size
        // immediately.
        grid.resize(cols: renderer.cols, rows: renderer.rows)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // Hook up the mouseMoved tracking area as soon as we have a window
        // — without one, AppKit only delivers mouseMoved when the window
        // has `acceptsMouseMovedEvents` set globally.
        refreshTrackingArea()
    }

    // MARK: keyboard -> closure

    override func keyDown(with event: NSEvent) {
        guard inputEnabled else {
            NSSound.beep()
            return
        }
        if let bytes = encodeKey(event) {
            onKey(bytes)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let Cmd-V paste into the terminal instead of menu handling it.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v"
        {
            guard inputEnabled else {
                NSSound.beep()
                return true
            }
            if let s = NSPasteboard.general.string(forType: .string) {
                onKey(Array(s.utf8))
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func encodeKey(_ event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags
        let keyCode = Int(event.keyCode)

        switch keyCode {
        case kVK_UpArrow:    return Array("\u{1B}[A".utf8)
        case kVK_DownArrow:  return Array("\u{1B}[B".utf8)
        case kVK_RightArrow: return Array("\u{1B}[C".utf8)
        case kVK_LeftArrow:  return Array("\u{1B}[D".utf8)
        case kVK_Return:     return [0x0D]
        case kVK_Tab:        return [0x09]
        case kVK_Delete:     return [0x7F] // Backspace
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

    // MARK: mouse -> SGR encoding (DECSET 1006)
    //
    // We forward macOS mouse events to the PTY using the xterm SGR encoding
    // when (a) the user has the sidebar "Mouse mode" toggle on and (b) the
    // running app has DECSET'd at least one of 1000/1002/1003 + 1006. The
    // rendering side (`renderer.cellSize`) gives us the per-cell size in
    // view points; combined with `event.locationInWindow` that's enough to
    // resolve a (col, row) one-based grid coordinate.
    //
    // Drag (1002) and any-motion (1003) reporting tack +32 onto the button
    // byte; scroll wheel uses 64/65 as the base button. We always emit SGR
    // bytes (lowercase 'm' for release, uppercase 'M' for press) and rely on
    // the host PTY's running app to route them appropriately.

    /// Bit-for-bit SGR button byte. `motion` is true for drag/move reports.
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

    /// Returns true iff we should intercept this mouse event and emit SGR
    /// bytes. The user toggle takes precedence over the running app's
    /// DECSET state — we don't want to fight the user when they've turned
    /// mouse mode off, even if a TUI happens to have it requested.
    private var shouldReportMouse: Bool {
        guard mouseModeEnabled else { return false }
        let term = grid.term
        // Need either X10/drag/move active to know what to report. SGR
        // (bit 3) is the encoding flag — without it we'd otherwise have
        // to fall back to the legacy 6-bit byte format which we don't
        // implement; treat 1006-less requests as "ignore for now".
        guard term.x10Mouse || term.dragMouse || term.anyMotionMouse else {
            return false
        }
        guard term.sgrMouse else { return false }
        return true
    }

    /// Translate a window-coordinate event location into a 0-based (col, row)
    /// grid cell, plus a flag indicating whether the location was inside the
    /// usable terminal area. We clamp to the grid edges so a click in the
    /// sub-cell padding still produces a sensible coordinate, but report
    /// `inside = false` when the pointer is fully outside the rendered
    /// drawable so callers can suppress motion reports.
    private func gridCell(for event: NSEvent) -> (col: Int, row: Int, inside: Bool) {
        let p = convert(event.locationInWindow, from: nil)
        let cell = renderer.cellSize
        let cw = max(cell.width, 0.5)
        let ch = max(cell.height, 0.5)
        // Mouse Y is bottom-up in our (un-flipped) NSView; the renderer
        // uses top-down rows.
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

    private func sgrModifierBits(_ flags: NSEvent.ModifierFlags) -> Int {
        var b = 0
        if flags.contains(.shift)   { b |= SGRButton.shiftFlag }
        if flags.contains(.option)  { b |= SGRButton.altFlag }
        if flags.contains(.control) { b |= SGRButton.ctrlFlag }
        return b
    }

    /// Encode a single SGR mouse report and ship it through the standard
    /// `onKey` path. `pressed = false` selects the lowercase 'm' release
    /// terminator; `pressed = true` uses uppercase 'M'. `motion = true`
    /// folds in the +32 motion flag.
    private func emitSGR(button: Int,
                         col: Int,
                         row: Int,
                         pressed: Bool,
                         motion: Bool,
                         flags: NSEvent.ModifierFlags)
    {
        let cb = button | sgrModifierBits(flags) | (motion ? SGRButton.motionFlag : 0)
        // 1-based per VT spec.
        let c1 = col + 1
        let r1 = row + 1
        let terminator: UInt8 = pressed ? 0x4D /* 'M' */ : 0x6D /* 'm' */
        var bytes: [UInt8] = [0x1B, 0x5B, 0x3C] // ESC [ <
        bytes.append(contentsOf: Array(String(cb).utf8))
        bytes.append(0x3B) // ;
        bytes.append(contentsOf: Array(String(c1).utf8))
        bytes.append(0x3B) // ;
        bytes.append(contentsOf: Array(String(r1).utf8))
        bytes.append(terminator)
        onKey(bytes)
    }

    private func reportClick(event: NSEvent, button: Int, pressed: Bool) {
        let cell = gridCell(for: event)
        // Press/release outside the grid are still useful (e.g. a release
        // that ends a drag started inside) — clamp coords and report.
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

    private func reportMotion(event: NSEvent, button: Int, isDrag: Bool) {
        let cell = gridCell(for: event)

        // Suppress duplicate same-cell motion reports — TUIs only need one
        // event per cell crossing.
        if cell.inside,
           cell.col == lastMotionCol,
           cell.row == lastMotionRow,
           lastMotionInside
        {
            return
        }
        if !cell.inside, !lastMotionInside {
            // Once outside, stop spamming reports.
            return
        }

        // 30Hz floor for any-motion (1003); drag (1002) is naturally rate-
        // limited by the user moving the mouse with a button held but we
        // throttle there too just in case (trackpad inertia).
        let now = CACurrentMediaTime()
        if now - lastMotionTime < Self.motionMinInterval {
            return
        }
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

    // MARK: mouse handlers
    //
    // Each override checks `shouldReportMouse` first. When false we fall
    // through to `super`, which preserves the pre-issue-26 behavior
    // (mouseDown gives focus, scroll wheel does nothing in our app, right-
    // click is available for the system menu, etc.).

    override func mouseDown(with event: NSEvent) {
        // Always become first responder on click — the hitTest override
        // routes us here regardless of mouse mode.
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        guard shouldReportMouse else {
            super.mouseDown(with: event)
            return
        }
        reportClick(event: event, button: SGRButton.left, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard shouldReportMouse else {
            super.mouseUp(with: event)
            return
        }
        reportClick(event: event, button: SGRButton.left, pressed: false)
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
        // NSEvent.buttonNumber: 0 = left, 1 = right, 2 = middle, 3+ = aux.
        // SGR has no defined encoding for buttons 4+ so we collapse to
        // middle for everything in this catch-all overload.
        reportClick(event: event, button: SGRButton.middle, pressed: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard shouldReportMouse else {
            super.otherMouseUp(with: event)
            return
        }
        reportClick(event: event, button: SGRButton.middle, pressed: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard shouldReportMouse else {
            super.mouseDragged(with: event)
            return
        }
        // 1002 covers drag (button held) regardless of which button — we
        // forward when either drag or any-motion is active.
        guard grid.term.dragMouse || grid.term.anyMotionMouse else { return }
        reportMotion(event: event, button: SGRButton.left, isDrag: true)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard shouldReportMouse else {
            super.rightMouseDragged(with: event)
            return
        }
        guard grid.term.dragMouse || grid.term.anyMotionMouse else { return }
        reportMotion(event: event, button: SGRButton.right, isDrag: true)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard shouldReportMouse else {
            super.otherMouseDragged(with: event)
            return
        }
        guard grid.term.dragMouse || grid.term.anyMotionMouse else { return }
        reportMotion(event: event, button: SGRButton.middle, isDrag: true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard shouldReportMouse else {
            super.mouseMoved(with: event)
            return
        }
        // Only DECSET 1003 wants buttonless motion reports.
        guard grid.term.anyMotionMouse else { return }
        // Sentinel button-byte 3 ("released" / no button) per xterm's
        // any-motion convention; folded with the +32 motion flag.
        reportMotion(event: event, button: 3, isDrag: false)
    }

    override func scrollWheel(with event: NSEvent) {
        guard shouldReportMouse else {
            super.scrollWheel(with: event)
            return
        }
        // macOS gives us a continuous deltaY (incl. inertia). For SGR we
        // need discrete clicks: emit one button-down report per scroll
        // notch. We treat anything below 0.1 pt as no-op to avoid spam at
        // the tail of a flick. Vertical only — horizontal scroll on
        // trackpads doesn't have a standard SGR encoding.
        let dy = event.scrollingDeltaY
        if abs(dy) < 0.1 {
            return
        }
        let cell = gridCell(for: event)
        let button = dy > 0 ? SGRButton.scrollUp : SGRButton.scrollDown
        // Scroll wheel reports use 'M' (press) only; there's no release.
        emitSGR(
            button: button,
            col: cell.col,
            row: cell.row,
            pressed: true,
            motion: false,
            flags: event.modifierFlags)
    }

    // MARK: tracking-area management for mouseMoved (DECSET 1003)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea()
    }

    /// Add / remove the tracking area that turns mouseMoved into something
    /// AppKit will deliver to us. We keep the area live whenever the user
    /// toggle is on so we don't have to re-poll DECSET state through the
    /// SwiftUI updateNSView path — `mouseMoved(with:)` itself short-circuits
    /// when `anyMotionMouse` is false, so the cost of an idle tracking area
    /// is just NSEvent dispatch we discard immediately.
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
}

/// SwiftUI bridge. Caller supplies the grid and closures; this view is
/// agnostic to whether the bytes come from a local PTY or a remote host.
struct MetalTerminalView: NSViewRepresentable {
    let grid: GridModel
    let onKey: ([UInt8]) -> Void
    let onResize: (UInt16, UInt16) -> Void
    let inputEnabled: Bool
    /// Master switch for SGR mouse-reporting (the "Mouse mode" sidebar
    /// toggle). When false, mouse events fall through to default NSView
    /// behavior even if the running app has DECSET 1000/1002/1003.
    let mouseModeEnabled: Bool

    init(grid: GridModel,
         onKey: @escaping ([UInt8]) -> Void,
         onResize: @escaping (UInt16, UInt16) -> Void = { _, _ in },
         inputEnabled: Bool = true,
         mouseModeEnabled: Bool = true)
    {
        self.grid = grid
        self.onKey = onKey
        self.onResize = onResize
        self.inputEnabled = inputEnabled
        self.mouseModeEnabled = mouseModeEnabled
    }

    func makeNSView(context: Context) -> MetalTerminalNSView {
        guard let v = MetalTerminalNSView(
            grid: grid, onKey: onKey, onResize: onResize)
        else {
            NSLog("MetalTerminalNSView init failed — Metal unavailable")
            // Return an empty placeholder view rather than crash.
            return MetalTerminalNSView(
                grid: grid, onKey: { _ in }, onResize: { _, _ in })!
        }
        v.inputEnabled = inputEnabled
        v.mouseModeEnabled = mouseModeEnabled
        return v
    }

    func updateNSView(_ nsView: MetalTerminalNSView, context: Context) {
        nsView.updateGrid(grid)
        nsView.inputEnabled = inputEnabled
        nsView.mouseModeEnabled = mouseModeEnabled
        // Tracking area depends on both the toggle AND the live DECSET
        // bitmask — re-evaluate every update so the area appears the
        // moment a TUI sets 1003.
        nsView.refreshTrackingArea()
    }
}
