import SwiftUI
import AppKit
import Metal
import MetalKit
import Carbon.HIToolbox

/// NSView subclass: MTKView wrapper that owns the `TerminalRenderer` and
/// routes keystrokes into a `PTYSession`. Feeds PTY output bytes into a
/// `TermCore` backed by libcollabterm.
final class MetalTerminalNSView: NSView {
    let mtkView: MTKView
    let renderer: TerminalRenderer
    let term: TermCore
    let session: PTYSession

    init?(session: PTYSession) {
        let view = MTKView(frame: .zero)
        self.mtkView = view
        // TermCore size is recomputed on first layout.
        guard let term = TermCore(cols: 80, rows: 24) else { return nil }
        self.term = term
        guard let renderer = TerminalRenderer(view: view) else { return nil }
        self.renderer = renderer
        self.session = session
        super.init(frame: .zero)

        renderer.term = term

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
            self.term.resize(cols: cols, rows: rows)
            self.session.resize(cols: cols, rows: rows)
        }

        session.onOutput = { [weak self] bytes in
            self?.term.feed(bytes)
        }
        session.onExit = { [weak self] in
            let msg: [UInt8] = Array("\r\n[process exited]\r\n".utf8)
            self?.term.feed(msg)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: keyboard -> PTY

    override func keyDown(with event: NSEvent) {
        if let bytes = encodeKey(event) {
            session.send(bytes)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let Cmd-V paste into the terminal instead of menu handling it.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v"
        {
            if let s = NSPasteboard.general.string(forType: .string) {
                session.send(Array(s.utf8))
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

/// SwiftUI bridge.
struct MetalTerminalView: NSViewRepresentable {
    let session: PTYSession

    func makeNSView(context: Context) -> MetalTerminalNSView {
        guard let v = MetalTerminalNSView(session: session) else {
            // If Metal init failed (unlikely on Apple silicon), return an
            // empty placeholder view so the app doesn't crash.
            NSLog("MetalTerminalNSView init failed")
            let dummy = MetalTerminalNSView.placeholder()
            return dummy
        }
        return v
    }

    func updateNSView(_ nsView: MetalTerminalNSView, context: Context) {}
}

private extension MetalTerminalNSView {
    static func placeholder() -> MetalTerminalNSView {
        // Unsafe fallback — only hit if Metal is unavailable.
        let session = PTYSession()
        return MetalTerminalNSView(session: session) ?? {
            fatalError("Metal unavailable")
        }()
    }
}
