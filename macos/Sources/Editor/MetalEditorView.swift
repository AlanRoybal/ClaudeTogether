import SwiftUI
import AppKit
import Metal
import MetalKit
import Carbon.HIToolbox

final class MetalEditorNSView: NSView {
    let mtkView: MTKView
    let renderer: EditorRenderer

    private(set) var controller: EditorController
    private(set) var grid: EditorGridModel

    init?(controller: EditorController) {
        let view = MTKView(frame: .zero)
        self.mtkView = view
        self.controller = controller
        self.grid = EditorGridModel(controller: controller)
        guard let renderer = EditorRenderer(view: view) else { return nil }
        self.renderer = renderer

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
            self?.grid.resize(cols: cols, rows: rows)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func updateController(_ controller: EditorController) {
        guard self.controller !== controller else { return }
        self.controller = controller
        self.grid = EditorGridModel(controller: controller)
        renderer.grid = grid
        grid.resize(cols: renderer.cols, rows: renderer.rows)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if handleSpecialKey(event) { return }
        if let text = plainText(from: event) {
            controller.apply(.insert(text))
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s":
            controller.requestSave()
            return true
        case "w":
            controller.requestClose()
            return true
        case "z":
            if event.modifierFlags.contains(.shift) {
                controller.apply(.redo)
            } else {
                controller.apply(.undo)
            }
            return true
        case "v":
            if let value = NSPasteboard.general.string(forType: .string) {
                controller.apply(.paste(value))
            }
            return true
        case "a":
            controller.state.localSelectionAnchor = 0
            controller.state.localCaret = controller.state.text.unicodeScalars.count
            controller.state.epoch &+= 1
            controller.broadcastPresenceNow()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let magnitude = max(1, Int(abs(event.scrollingDeltaY) / 12.0))
        let delta = event.scrollingDeltaY > 0 ? -magnitude : magnitude
        grid.scroll(byRows: delta)
    }

    private func handleSpecialKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .option, .command])
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let command = flags.contains(.command)

        let intent: EditorIntent?
        switch Int(event.keyCode) {
        case kVK_LeftArrow:
            intent = command ? .moveLineStart : .moveLeft(byWord: option)
        case kVK_RightArrow:
            intent = command ? .moveLineEnd : .moveRight(byWord: option)
        case kVK_UpArrow:
            intent = command ? .moveDocStart : .moveUp
        case kVK_DownArrow:
            intent = command ? .moveDocEnd : .moveDown
        case kVK_Home:
            intent = .moveDocStart
        case kVK_End:
            intent = .moveDocEnd
        case kVK_Return:
            intent = .insert("\n")
        case kVK_Tab:
            intent = .insert("    ")
        case kVK_Delete:
            intent = .backspace
        case kVK_ForwardDelete:
            intent = .deleteForward
        default:
            intent = nil
        }

        guard let resolved = intent else { return false }
        if shift, isMovement(resolved) {
            controller.apply(.selectExtend(resolved))
        } else {
            controller.apply(resolved)
        }
        return true
    }

    private func plainText(from event: NSEvent) -> String? {
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) {
            return nil
        }
        guard let chars = event.characters, !chars.isEmpty else { return nil }
        let scalars = chars.unicodeScalars
        guard !scalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        return chars
    }

    private func isMovement(_ intent: EditorIntent) -> Bool {
        switch intent {
        case .moveLeft, .moveRight, .moveUp, .moveDown,
             .moveLineStart, .moveLineEnd, .moveDocStart, .moveDocEnd:
            return true
        default:
            return false
        }
    }
}

struct MetalEditorView: NSViewRepresentable {
    let controller: EditorController

    func makeNSView(context: Context) -> MetalEditorNSView {
        guard let view = MetalEditorNSView(controller: controller) else {
            fatalError("MetalEditorNSView init failed")
        }
        return view
    }

    func updateNSView(_ nsView: MetalEditorNSView, context: Context) {
        nsView.updateController(controller)
    }
}
