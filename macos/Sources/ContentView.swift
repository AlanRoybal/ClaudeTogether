import SwiftUI
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

    init() {
        coreVersion = ct_version()
        if let url = Bundle.main.url(forResource: "bore", withExtension: nil) {
            boreBundlePath = url.path
        }
    }

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
    }
}
