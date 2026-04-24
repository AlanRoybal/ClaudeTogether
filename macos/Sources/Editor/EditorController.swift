import Foundation
import AppKit

/// High-level user intents produced by the editor view in response to
/// NSEvents. The controller translates these into CRDT ops + caret
/// motion. Keeping the view -> controller surface as a flat enum means
/// the renderer layer (Step 4) never touches `EditorCore` directly.
enum EditorIntent {
    case insert(String)
    case backspace
    case deleteForward
    case moveLeft(byWord: Bool)
    case moveRight(byWord: Bool)
    case moveUp
    case moveDown
    case moveLineStart
    case moveLineEnd
    case moveDocStart
    case moveDocEnd
    indirect case selectExtend(EditorIntent)
    case clearSelection
    case paste(String)
    case undo
    case redo
}

/// Drives the RGA CRDT on behalf of the local user and fans local ops
/// out via the `sendOp` closure. Presence (caret-anchor broadcasts) is
/// debounced 50 ms so that running the caret across a line doesn't
/// flood the network. @MainActor because it reads/writes `@Published`
/// state on `EditorState` and is called from NSEvent handlers.
@MainActor
final class EditorController {
    /// Observable state — the Metal renderer and any SwiftUI overlays
    /// subscribe to this.
    let state: EditorState

    /// CRDT replica. Owned exclusively by this controller.
    private let core: EditorCore

    /// Egress for local CRDT ops. Step 5 wires this to
    /// `SessionManager.sendEditorOp`.
    private let sendOp: (Data) -> Void

    /// Egress for presence (anchor, selection-anchor). Step 5 wires
    /// this to `SessionManager.sendEditorPresence`.
    private let sendPresence: (CrdtId?, CrdtId?) -> Void

    /// Local save / close requests. The host handles these directly;
    /// peers route them back to the host.
    private let requestSaveAction: () -> Void
    private let requestCloseAction: () -> Void

    /// Debounce token for presence broadcasts.
    private var presenceWork: DispatchWorkItem?

    // MARK: Undo/redo

    /// Inverse of a local op, sufficient to undo it against the CRDT.
    /// Stored on the per-actor undo stack; we never undo remote ops.
    private enum InverseOp {
        /// Undo an insert: delete the item we inserted.
        case deleteId(CrdtId)
        /// Undo a delete: re-insert `codepoint` after `after` (nil =
        /// insert at document head).
        case reinsert(after: CrdtId?, codepoint: UInt32)
    }

    /// Undo entry — a batch of inverse ops representing one user
    /// action (e.g. deleting a selection is one entry with N inverses).
    /// Ops are stored in the order they should be *applied* to undo.
    private struct UndoEntry {
        var inverses: [InverseOp]
        /// Caret position to restore after undo. Redo's entry stores the
        /// *pre-redo* caret the same way.
        var caretAfter: Int
        var selectionAnchorAfter: Int?
    }

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private static let maxStackSize = 1000

    /// If true, operations currently being applied are part of an
    /// undo/redo — don't push more undo entries.
    private var applyingInverse: Bool = false

    // MARK: Init

    init(docId: UInt64,
         path: String,
         clientId: UInt32,
         localCursorColor: NSColor,
         snapshot: Data,
         sendOp: @escaping (Data) -> Void,
         sendPresence: @escaping (CrdtId?, CrdtId?) -> Void,
         requestSave: @escaping () -> Void = {},
         requestClose: @escaping () -> Void = {})
    {
        self.state = EditorState(docId: docId, path: path, clientId: clientId)
        self.state.localCursorColor = localCursorColor
        self.sendOp = sendOp
        self.sendPresence = sendPresence
        self.requestSaveAction = requestSave
        self.requestCloseAction = requestClose

        guard let core = EditorCore(clientId: clientId) else {
            // Matches the existing pattern of crashing on core init
            // failure — these failures only happen on OOM.
            fatalError("EditorController: EditorCore init failed")
        }
        self.core = core

        if !snapshot.isEmpty {
            do {
                try core.loadSnapshot(snapshot)
            } catch {
                NSLog("EditorController: loadSnapshot failed: \(error)")
            }
        }
        refreshText()
    }

    // MARK: Public helpers

    var snapshotData: Data { Data(state.text.utf8) }

    func requestSave() {
        requestSaveAction()
    }

    func requestClose() {
        requestCloseAction()
    }

    func broadcastPresenceNow() {
        firePresence()
    }

    /// Convert an anchor ("caret sits after this item") into a visible
    /// caret offset.
    func visibleOffset(for anchor: CrdtId?) -> Int {
        guard let anchor else { return 0 }
        guard let pos = core.posOfId(anchor) else { return 0 }
        return min(scalarCount, pos + 1)
    }

    // MARK: Save state

    /// Called by Step 5/6 in response to an inbound `editorSaved`.
    func markSaved(rev: UInt32) {
        state.lastSavedRev = rev
        state.dirty = false
        bumpEpoch()
    }

    // MARK: Remote ops

    /// Apply an inbound `editorOp` and rebase the local caret/selection
    /// across the change. We anchor the caret to the CRDT id of the
    /// character it currently sits after; the anchor survives arbitrary
    /// concurrent edits because it's tombstone-stable.
    func onRemoteOp(_ data: Data) {
        let caretAnchor = core.idAtPos(max(0, state.localCaret - 1))
        let selAnchor: CrdtId? = state.localSelectionAnchor.flatMap { anchor in
            core.idAtPos(max(0, anchor - 1))
        }

        let changed: Bool
        do {
            changed = try core.applyOp(data)
        } catch {
            NSLog("EditorController.onRemoteOp: apply failed: \(error)")
            return
        }
        guard changed else { return }
        refreshText()

        // Rebase caret. nil anchor == caret was at head; keep at 0.
        if state.localCaret == 0 {
            state.localCaret = 0
        } else if let a = caretAnchor, let p = core.posOfId(a) {
            state.localCaret = min(scalarCount, p + 1)
        } else {
            state.localCaret = min(scalarCount, state.localCaret)
        }

        if let anchor = state.localSelectionAnchor {
            if anchor == 0 {
                state.localSelectionAnchor = 0
            } else if let sa = selAnchor, let p = core.posOfId(sa) {
                state.localSelectionAnchor = min(scalarCount, p + 1)
            } else {
                state.localSelectionAnchor = min(scalarCount, anchor)
            }
        }

        bumpEpoch()
    }

    /// Remote user moved their caret. Colour is passed in from the
    /// roster (Step 5 wiring) so we don't duplicate palette logic here.
    func onRemotePresence(userId: UserIdentity,
                          anchor: CrdtId?,
                          selectionAnchor: CrdtId?,
                          color: NSColor)
    {
        state.remoteCursors[userId] = RemoteCursor(
            anchor: anchor,
            selectionAnchor: selectionAnchor,
            color: color)
        bumpEpoch()
    }

    /// Drop a remote user's cursor (on disconnect or session teardown).
    func removeRemoteUser(_ userId: UserIdentity) {
        if state.remoteCursors.removeValue(forKey: userId) != nil {
            bumpEpoch()
        }
    }

    // MARK: Intent dispatch

    /// Entry point for every local user action. Movement intents only
    /// shift the caret (and maybe selection); mutation intents generate
    /// and broadcast CRDT ops.
    func apply(_ intent: EditorIntent) {
        switch intent {
        case .insert(let s):
            insertText(s)
        case .paste(let s):
            insertText(s)
        case .backspace:
            backspace()
        case .deleteForward:
            deleteForward()
        case .clearSelection:
            state.localSelectionAnchor = nil
            bumpEpoch()
        case .selectExtend(let movement):
            if state.localSelectionAnchor == nil {
                state.localSelectionAnchor = state.localCaret
            }
            applyMovement(movement)
            bumpEpoch()
            schedulePresence()
            return
        case .undo:
            performUndo()
        case .redo:
            performRedo()
        default:
            // Movement intents (not wrapped by selectExtend): collapse
            // any selection to the caret, then move.
            if state.localSelectionAnchor != nil {
                state.localSelectionAnchor = nil
            }
            applyMovement(intent)
            bumpEpoch()
            schedulePresence()
            return
        }
        bumpEpoch()
        schedulePresence()
    }

    // MARK: - Mutation

    /// Insert a string: if a selection exists delete it first, then
    /// emit one op per unicode scalar. Multi-scalar grapheme clusters
    /// (emoji with combining marks, flags, etc.) are split into their
    /// component scalars — the plan explicitly scopes v1 to scalars.
    private func insertText(_ s: String) {
        guard !s.isEmpty else { return }
        var inverses: [InverseOp] = []
        if state.localSelectionAnchor != nil {
            if let delInv = deleteSelection() {
                inverses.append(contentsOf: delInv)
            }
        }

        let caretBefore = state.localCaret
        let selBefore = state.localSelectionAnchor

        for scalar in s.unicodeScalars {
            let pos = state.localCaret
            do {
                let opData = try core.localInsert(
                    at: pos, codepoint: scalar.value)
                sendOp(opData)
                // The inserted item is now the live item at visible
                // offset `pos`.
                if let newId = core.idAtPos(pos) {
                    inverses.append(.deleteId(newId))
                }
                state.localCaret = pos + 1
            } catch {
                NSLog("EditorController.insert failed: \(error)")
                return
            }
        }
        refreshText()
        state.dirty = true

        if !applyingInverse && !inverses.isEmpty {
            // Inverses are applied in reverse for undo (undo the last
            // insert first so character visible offsets line up).
            pushUndo(UndoEntry(
                inverses: inverses.reversed(),
                caretAfter: caretBefore,
                selectionAnchorAfter: selBefore))
            redoStack.removeAll()
        }
    }

    /// Backspace: if there's a selection delete it, else delete the
    /// character to the left of the caret.
    private func backspace() {
        if state.localSelectionAnchor != nil {
            if let inverses = deleteSelection() {
                finishMutation(inverses: inverses)
            }
            return
        }
        let caret = state.localCaret
        guard caret > 0 else { return }
        let pos = caret - 1
        guard let inv = deleteOne(at: pos) else { return }
        state.localCaret = pos
        finishMutation(inverses: [inv])
    }

    /// Delete-forward: if selection delete it, else delete the
    /// character at the caret (caret stays put; the text to its right
    /// slides left).
    private func deleteForward() {
        if state.localSelectionAnchor != nil {
            if let inverses = deleteSelection() {
                finishMutation(inverses: inverses)
            }
            return
        }
        let caret = state.localCaret
        guard caret < scalarCount else { return }
        guard let inv = deleteOne(at: caret) else { return }
        finishMutation(inverses: [inv])
    }

    /// Delete one character at visible position `pos`. Captures the
    /// inverse (`reinsert`) before mutating so undo works even though
    /// `idAtPos(pos-1)` may shift after the op.
    private func deleteOne(at pos: Int) -> InverseOp? {
        let chars = scalarArray
        guard pos >= 0, pos < chars.count else { return nil }
        let scalar = chars[pos]
        let afterId: CrdtId? = pos == 0 ? nil : core.idAtPos(pos - 1)

        do {
            guard let opData = try core.localDelete(at: pos) else {
                return nil
            }
            sendOp(opData)
        } catch {
            NSLog("EditorController.deleteOne failed: \(error)")
            return nil
        }
        return .reinsert(after: afterId, codepoint: scalar.value)
    }

    /// Delete the current selection range. Returns the ordered inverse
    /// list (ready to push onto the undo stack), or nil if no selection.
    private func deleteSelection() -> [InverseOp]? {
        guard let anchor = state.localSelectionAnchor else { return nil }
        let lo = min(anchor, state.localCaret)
        let hi = max(anchor, state.localCaret)
        guard hi > lo else {
            state.localSelectionAnchor = nil
            return nil
        }
        var inverses: [InverseOp] = []
        // Repeatedly delete at `lo` until length matches. Each delete
        // emits its own op on the wire — matches the plan spec.
        let count = hi - lo
        for _ in 0..<count {
            guard let inv = deleteOne(at: lo) else { break }
            inverses.append(inv)
        }
        state.localCaret = lo
        state.localSelectionAnchor = nil
        // Inverses applied in reverse to rebuild the selection in order.
        return inverses.reversed()
    }

    /// Finish a mutation: refresh derived state, mark dirty, push undo.
    private func finishMutation(inverses: [InverseOp]) {
        refreshText()
        state.dirty = true
        if !applyingInverse && !inverses.isEmpty {
            pushUndo(UndoEntry(
                inverses: inverses,
                caretAfter: state.localCaret,
                selectionAnchorAfter: state.localSelectionAnchor))
            redoStack.removeAll()
        }
    }

    private func pushUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > Self.maxStackSize {
            undoStack.removeFirst(undoStack.count - Self.maxStackSize)
        }
    }

    // MARK: - Undo / redo

    /// Pop one entry, apply its inverses (broadcasting each), push the
    /// inverse-of-the-inverse onto redo. Gracefully skips inverses that
    /// no longer apply (e.g. a remote user deleted our insert already).
    private func performUndo() { swapStacks(from: \.undoStack, to: \.redoStack) }
    private func performRedo() { swapStacks(from: \.redoStack, to: \.undoStack) }

    private func swapStacks(
        from fromKP: ReferenceWritableKeyPath<EditorController, [UndoEntry]>,
        to toKP: ReferenceWritableKeyPath<EditorController, [UndoEntry]>)
    {
        guard !self[keyPath: fromKP].isEmpty else { return }
        let entry = self[keyPath: fromKP].removeLast()
        applyingInverse = true
        defer { applyingInverse = false }

        var reverseInverses: [InverseOp] = []
        for inv in entry.inverses {
            if let rev = applyInverse(inv) {
                reverseInverses.append(rev)
            }
        }
        refreshText()
        state.dirty = true
        state.localCaret = min(entry.caretAfter, scalarCount)
        state.localSelectionAnchor = entry.selectionAnchorAfter
            .map { min($0, scalarCount) }

        if !reverseInverses.isEmpty {
            let redoEntry = UndoEntry(
                inverses: reverseInverses.reversed(),
                caretAfter: state.localCaret,
                selectionAnchorAfter: state.localSelectionAnchor)
            self[keyPath: toKP].append(redoEntry)
            if self[keyPath: toKP].count > Self.maxStackSize {
                self[keyPath: toKP].removeFirst(
                    self[keyPath: toKP].count - Self.maxStackSize)
            }
        }
        bumpEpoch()
        schedulePresence()
    }

    /// Apply one inverse op against the CRDT and broadcast. Returns the
    /// inverse-of-the-inverse for redo-stack bookkeeping, or nil if the
    /// op no-op'd (e.g. the target id is already tombstoned).
    private func applyInverse(_ inv: InverseOp) -> InverseOp? {
        switch inv {
        case .deleteId(let id):
            guard let pos = core.posOfId(id) else { return nil }
            // Capture the scalar *before* deleting so we can redo.
            let chars = scalarArray
            let scalar: UInt32?
            if pos < chars.count {
                scalar = chars[pos].value
            } else {
                scalar = nil
            }
            let afterId: CrdtId? = pos == 0 ? nil : core.idAtPos(pos - 1)
            do {
                guard let opData = try core.localDelete(at: pos) else {
                    return nil
                }
                sendOp(opData)
                refreshText()
            } catch {
                NSLog("applyInverse.deleteId failed: \(error)")
                return nil
            }
            if let s = scalar {
                return .reinsert(after: afterId, codepoint: s)
            }
            return nil

        case .reinsert(let after, let codepoint):
            let pos: Int
            if let a = after {
                guard let p = core.posOfId(a) else { return nil }
                pos = p + 1
            } else {
                pos = 0
            }
            do {
                let opData = try core.localInsert(
                    at: pos, codepoint: codepoint)
                sendOp(opData)
                refreshText()
            } catch {
                NSLog("applyInverse.reinsert failed: \(error)")
                return nil
            }
            if let newId = core.idAtPos(pos) {
                return .deleteId(newId)
            }
            return nil
        }
    }

    // MARK: - Movement

    /// Apply a movement intent. Only movement variants are handled here
    /// — non-movements are no-ops (they were already routed).
    private func applyMovement(_ intent: EditorIntent) {
        let count = scalarCount
        switch intent {
        case .moveLeft(byWord: false):
            state.localCaret = max(0, state.localCaret - 1)
        case .moveLeft(byWord: true):
            state.localCaret = wordLeft(from: state.localCaret)
        case .moveRight(byWord: false):
            state.localCaret = min(count, state.localCaret + 1)
        case .moveRight(byWord: true):
            state.localCaret = wordRight(from: state.localCaret)
        case .moveUp:
            state.localCaret = moveVertical(from: state.localCaret, delta: -1)
        case .moveDown:
            state.localCaret = moveVertical(from: state.localCaret, delta: +1)
        case .moveLineStart:
            state.localCaret = lineStart(before: state.localCaret)
        case .moveLineEnd:
            state.localCaret = lineEnd(atOrAfter: state.localCaret)
        case .moveDocStart:
            state.localCaret = 0
        case .moveDocEnd:
            state.localCaret = count
        default:
            break
        }
    }

    // Word motion: skip whitespace then non-whitespace in the direction
    // of travel. Matches the standard macOS Option-arrow behavior
    // closely enough for v1 (no Unicode word-break tables).
    private func wordLeft(from caret: Int) -> Int {
        let chars = scalarArray
        var i = caret
        while i > 0, chars[i - 1].properties.isWhitespace { i -= 1 }
        while i > 0, !chars[i - 1].properties.isWhitespace { i -= 1 }
        return i
    }

    private func wordRight(from caret: Int) -> Int {
        let chars = scalarArray
        var i = caret
        while i < chars.count, chars[i].properties.isWhitespace { i += 1 }
        while i < chars.count, !chars[i].properties.isWhitespace { i += 1 }
        return i
    }

    // Column-preserving vertical motion. Returns caret clamped to doc.
    private func moveVertical(from caret: Int, delta: Int) -> Int {
        let chars = scalarArray
        let lineStartIdx = lineStart(before: caret)
        let column = caret - lineStartIdx

        if delta < 0 {
            // Move to previous line.
            if lineStartIdx == 0 { return caret }
            // prevLineEnd is the '\n' at lineStartIdx - 1.
            let prevLineEnd = lineStartIdx - 1
            let prevLineStart = lineStart(before: prevLineEnd)
            let prevLineLen = prevLineEnd - prevLineStart
            return prevLineStart + min(column, prevLineLen)
        } else {
            // Move to next line.
            let currentLineEnd = lineEnd(atOrAfter: caret)
            if currentLineEnd >= chars.count { return caret }
            let nextLineStart = currentLineEnd + 1
            let nextLineEnd = lineEnd(atOrAfter: nextLineStart)
            let nextLineLen = nextLineEnd - nextLineStart
            return nextLineStart + min(column, nextLineLen)
        }
    }

    private func lineStart(before caret: Int) -> Int {
        let chars = scalarArray
        var i = caret
        while i > 0, chars[i - 1] != "\n" { i -= 1 }
        return i
    }

    private func lineEnd(atOrAfter caret: Int) -> Int {
        let chars = scalarArray
        var i = caret
        while i < chars.count, chars[i] != "\n" { i += 1 }
        return i
    }

    // MARK: - Presence debounce

    /// Debounce 50 ms after the last caret motion, then broadcast.
    /// Anchors are CRDT ids so remote peers can resolve to their own
    /// visible offsets even if concurrent ops are in flight.
    private func schedulePresence() {
        presenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.firePresence() }
        }
        presenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50),
                                      execute: work)
    }

    private func firePresence() {
        let caret = state.localCaret
        let selAnchor = state.localSelectionAnchor

        let caretId: CrdtId? = caret == 0
            ? nil
            : core.idAtPos(caret - 1)
        let selId: CrdtId? = selAnchor.flatMap { a in
            a == 0 ? nil : core.idAtPos(a - 1)
        }
        sendPresence(caretId, selId)
    }

    // MARK: - Utilities

    private func refreshText() {
        do {
            state.text = try core.toUtf8()
        } catch {
            NSLog("EditorController.refreshText failed: \(error)")
        }
    }

    private func bumpEpoch() {
        state.epoch &+= 1
    }

    private var scalarArray: [UnicodeScalar] {
        Array(state.text.unicodeScalars)
    }

    private var scalarCount: Int {
        state.text.unicodeScalars.count
    }
}
