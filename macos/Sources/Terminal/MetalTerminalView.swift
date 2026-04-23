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
}

/// SwiftUI bridge. Caller supplies the grid and closures; this view is
/// agnostic to whether the bytes come from a local PTY or a remote host.
struct MetalTerminalView: NSViewRepresentable {
    let grid: GridModel
    let onKey: ([UInt8]) -> Void
    let onResize: (UInt16, UInt16) -> Void
    let inputEnabled: Bool

    init(grid: GridModel,
         onKey: @escaping ([UInt8]) -> Void,
         onResize: @escaping (UInt16, UInt16) -> Void = { _, _ in },
         inputEnabled: Bool = true)
    {
        self.grid = grid
        self.onKey = onKey
        self.onResize = onResize
        self.inputEnabled = inputEnabled
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
        return v
    }

    func updateNSView(_ nsView: MetalTerminalNSView, context: Context) {
        nsView.updateGrid(grid)
        nsView.inputEnabled = inputEnabled
    }
}
