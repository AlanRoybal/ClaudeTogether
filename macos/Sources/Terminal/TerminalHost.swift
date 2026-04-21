import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm's TerminalView, fed by a PTYSession.
struct TerminalHost: NSViewRepresentable {
    let session: PTYSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let tv = SwiftTerm.TerminalView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv

        session.onOutput = { [weak tv] bytes in
            tv?.feed(byteArray: bytes[...])
        }
        session.onExit = { [weak tv] in
            tv?.feed(text: "\r\n[process exited]\r\n")
        }
        return tv
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: PTYSession
        weak var terminalView: SwiftTerm.TerminalView?

        init(session: PTYSession) { self.session = session }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            session.send(Array(data))
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            let cols = max(1, min(Int(UInt16.max), newCols))
            let rows = max(1, min(Int(UInt16.max), newRows))
            session.resize(cols: UInt16(cols), rows: UInt16(rows))
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            let s = String(data: content, encoding: .utf8) ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
    }
}
