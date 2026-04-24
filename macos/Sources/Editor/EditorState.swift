import Foundation
import AppKit
import Combine

/// One remote user's cursor in the editor. Stored as CRDT anchors so the
/// cursor stays pinned to the character it's sitting after even as
/// concurrent ops shift the visible offset. The renderer resolves these
/// to visible positions on each frame via `EditorCore.posOfId`.
struct RemoteCursor: Equatable {
    var anchor: CrdtId?
    var selectionAnchor: CrdtId?
    var color: NSColor
}

/// Passive value holder for the collaborative editor. Mutation goes
/// through `EditorController` — no one else should write these fields.
/// `@Published` bumps drive SwiftUI / renderer refresh. `epoch` is the
/// monotonic dirty counter the Metal renderer compares against.
@MainActor
final class EditorState: ObservableObject {
    /// Current materialized document text. Refreshed from the CRDT
    /// after every local or remote mutation.
    @Published var text: String = ""

    /// Visible caret offset in unicode scalars / CRDT-visible positions,
    /// not bytes.
    @Published var localCaret: Int = 0

    /// If non-nil, there is an active selection anchored here; the head
    /// is `localCaret`. Cleared on `.clearSelection` or on mutation that
    /// collapses it.
    @Published var localSelectionAnchor: Int? = nil

    /// Per-remote-user cursor/selection state, keyed by identity.
    @Published var remoteCursors: [UserIdentity: RemoteCursor] = [:]

    /// Local user's editor cursor color.
    @Published var localCursorColor: NSColor = NSColor(
        srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1.0)

    /// Bumped by the controller on every state-visible change so the
    /// renderer can early-out when nothing changed.
    @Published var epoch: UInt64 = 0

    /// True when the local replica has un-saved local edits relative to
    /// the last acknowledged `editorSaved` from the host.
    @Published var dirty: Bool = false

    /// Last rev announced via `editorSaved`. Step 6 wires the increment.
    @Published var lastSavedRev: UInt32 = 0

    /// Stable document id assigned by whoever opened the editor. Used
    /// to route `editorOp`/`editorPresence` frames to the right doc.
    let docId: UInt64

    /// Session-relative path the editor is bound to.
    let path: String

    /// This replica's CRDT client id.
    let clientId: UInt32

    init(docId: UInt64, path: String, clientId: UInt32) {
        self.docId = docId
        self.path = path
        self.clientId = clientId
    }
}
