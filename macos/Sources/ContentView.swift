import SwiftUI
import Combine
import CollabTermC

struct ContentView: View {
    @StateObject private var model = TerminalModel()

    var body: some View {
        HSplitView {
            SessionSidebar(model: model)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            if let session = model.session {
                MetalTerminalView(session: session)
                    .frame(minWidth: 500, minHeight: 300)
            } else {
                VStack(spacing: 16) {
                    Text("ClaudeTogether")
                        .font(.largeTitle)
                        .bold()
                    Text("Pick a folder to use as the session root.")
                        .foregroundStyle(.secondary)
                    Button("Choose folder…") { model.startSession() }
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 550)
    }
}

@MainActor
final class TerminalModel: ObservableObject {
    @Published var session: PTYSession?
    @Published var rootPath: String?
    @Published var boreBundlePath: String?
    @Published var coreVersion: Int32 = 0

    let sessionManager = SessionManager()

    init() {
        coreVersion = ct_version()
        if let url = Bundle.main.url(forResource: "bore", withExtension: nil) {
            boreBundlePath = url.path
        }
        // Re-publish child ObservableObject changes.
        sessionManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    func startSession() {
        guard let folder = FolderPicker.pick() else { return }
        let s = PTYSession()
        guard s.spawn(cwd: folder) else {
            NSLog("PTY spawn failed")
            return
        }
        rootPath = folder
        session = s
    }

    func endSession() {
        session?.terminate()
        session = nil
        rootPath = nil
        stopSharing()
    }

    // MARK: sharing

    func startSharing() {
        sessionManager.startHost()
        if let borePath = boreBundlePath {
            sessionManager.startBoreTunnel(borePath: borePath)
        }
    }

    func stopSharing() {
        sessionManager.stop()
    }

    func promptJoin() {
        let alert = NSAlert()
        alert.messageText = "Join shared session"
        alert.informativeText = "Enter host:port (e.g. bore.pub:12345 or 127.0.0.1:5555)"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "host:port"
        alert.accessoryView = input
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let raw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = raw.lastIndex(of: ":"),
              let port = UInt16(raw[raw.index(after: colon)...]),
              !raw[..<colon].isEmpty
        else {
            NSLog("join: malformed \(raw)")
            return
        }
        let host = String(raw[..<colon])
        sessionManager.stop()
        sessionManager.joinPeer(host: host, port: port)
    }
}
