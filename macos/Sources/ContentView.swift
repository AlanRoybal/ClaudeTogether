import SwiftUI
import CollabTermC

struct ContentView: View {
    @State private var coreStatus: String = "(not called)"
    @State private var boreStatus: String = "(not checked)"
    @State private var abiVersion: Int32 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ClaudeTogether")
                .font(.largeTitle)
                .bold()

            GroupBox("Zig core") {
                VStack(alignment: .leading) {
                    Text("ct_hello(): \(coreStatus)")
                    Text("ct_version(): \(abiVersion)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Bundled bore") {
                Text(boreStatus)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }

            Spacer()
        }
        .padding(24)
        .onAppear(perform: runPhase0Checks)
    }

    private func runPhase0Checks() {
        var buf = [UInt8](repeating: 0, count: 64)
        let written = buf.withUnsafeMutableBufferPointer { ptr in
            ct_hello(ptr.baseAddress, ptr.count)
        }
        if written > 0 {
            coreStatus = String(decoding: buf.prefix(Int(written)), as: UTF8.self)
        } else {
            coreStatus = "error (\(written))"
        }
        abiVersion = ct_version()

        if let url = Bundle.main.url(forResource: "bore", withExtension: nil) {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            boreStatus = "found at \(url.path)\nsize: \(size) bytes"
        } else {
            boreStatus = "NOT FOUND in bundle"
        }
    }
}
