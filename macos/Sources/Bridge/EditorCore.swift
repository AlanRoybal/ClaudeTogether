import Foundation
import CollabTermC

enum EditorCoreError: Error {
    case crdtFailure(String)
    case invalidUtf8
}

/// Swift-side handle for a libcollabterm `ct_doc` (collaborative document).
/// Wraps an RGA text CRDT with per-user stable cursor anchors. Owns the
/// pointer; caller is responsible for releasing it (or letting the object
/// die).
final class EditorCore {
    private var handle: OpaquePointer?

    init?(clientId: UInt32) {
        guard let h = ct_doc_create(clientId) else { return nil }
        self.handle = h
    }

    deinit {
        if let h = handle { ct_doc_destroy(h) }
        handle = nil
    }

    /// Bulk-load a UTF-8 snapshot into the doc. Each codepoint becomes a
    /// full CRDT item authored by the local client.
    func loadSnapshot(_ data: Data) throws {
        guard let h = handle else { throw EditorCoreError.crdtFailure("closed") }
        let rc = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return ct_doc_load_snapshot(h, nil, 0)
            }
            return ct_doc_load_snapshot(h, base, raw.count)
        }
        if rc != 0 { throw EditorCoreError.crdtFailure(Self.lastError()) }
    }

    /// Perform a local insert of `codepoint` at visible offset `pos`.
    /// Returns the encoded op bytes suitable for wire transmission.
    func localInsert(at pos: Int, codepoint: UInt32) throws -> Data {
        guard let h = handle else { throw EditorCoreError.crdtFailure("closed") }
        return try roundTripOp(stackCap: 256) { buf, lenPtr in
            ct_doc_local_insert(h, pos, codepoint, buf, lenPtr)
        }
    }

    /// Perform a local delete at visible offset `pos`. Returns the encoded
    /// op bytes, or `nil` if the position was out of range (no-op).
    func localDelete(at pos: Int) throws -> Data? {
        guard let h = handle else { throw EditorCoreError.crdtFailure("closed") }
        var stack = [UInt8](repeating: 0, count: 256)
        var len: Int = stack.count
        let rc = stack.withUnsafeMutableBufferPointer { buf -> Int32 in
            ct_doc_local_delete(h, pos, buf.baseAddress, &len)
        }
        switch rc {
        case 0:
            return Data(stack.prefix(len))
        case 1:
            return nil
        case -2:
            // Grow and retry.
            let needed = len
            var big = [UInt8](repeating: 0, count: needed)
            var bigLen = needed
            let rc2 = big.withUnsafeMutableBufferPointer { buf -> Int32 in
                ct_doc_local_delete(h, pos, buf.baseAddress, &bigLen)
            }
            switch rc2 {
            case 0: return Data(big.prefix(bigLen))
            case 1: return nil
            default: throw EditorCoreError.crdtFailure(Self.lastError())
            }
        default:
            throw EditorCoreError.crdtFailure(Self.lastError())
        }
    }

    /// Decode and apply a remote op. Returns whether the doc mutated.
    func applyOp(_ data: Data) throws -> Bool {
        guard let h = handle else { throw EditorCoreError.crdtFailure("closed") }
        var changed = false
        let rc = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return ct_doc_apply_op(h, nil, 0, &changed)
            }
            return ct_doc_apply_op(h, base, raw.count, &changed)
        }
        if rc != 0 { throw EditorCoreError.crdtFailure(Self.lastError()) }
        return changed
    }

    /// Materialize the current document as a UTF-8 string.
    func toUtf8() throws -> String {
        guard let h = handle else { throw EditorCoreError.crdtFailure("closed") }
        var cap: Int = 4096
        var buf = [UInt8](repeating: 0, count: cap)
        var len: Int = cap
        var rc = buf.withUnsafeMutableBufferPointer { p -> Int32 in
            ct_doc_to_utf8(h, p.baseAddress, &len)
        }
        if rc == -2 {
            cap = len
            buf = [UInt8](repeating: 0, count: cap)
            len = cap
            rc = buf.withUnsafeMutableBufferPointer { p -> Int32 in
                ct_doc_to_utf8(h, p.baseAddress, &len)
            }
        }
        if rc != 0 { throw EditorCoreError.crdtFailure(Self.lastError()) }
        guard let s = String(bytes: buf.prefix(len), encoding: .utf8) else {
            throw EditorCoreError.invalidUtf8
        }
        return s
    }

    /// Look up the CRDT id of the live item at visible offset `pos`.
    /// Returns nil if the position is out of range.
    func idAtPos(_ pos: Int) -> CrdtId? {
        guard let h = handle else { return nil }
        var client: UInt32 = 0
        var clock: UInt32 = 0
        let rc = ct_doc_id_at_pos(h, pos, &client, &clock)
        if rc != 0 { return nil }
        return CrdtId(client: client, clock: clock)
    }

    /// Resolve a CRDT id back to its current visible offset. Tombstones
    /// resolve to the offset of the next live item. Returns nil if the id
    /// is not in the sequence.
    func posOfId(_ id: CrdtId) -> Int? {
        guard let h = handle else { return nil }
        var pos: Int = 0
        let rc = ct_doc_pos_of_id(h, id.client, id.clock, &pos)
        if rc != 0 { return nil }
        return pos
    }

    // MARK: - helpers

    /// Call an encode-op-style C ABI function that follows the
    /// `(buf, *in_out_len) -> rc` round-trip pattern. `rc == 0` success,
    /// `rc == -2` grow buffer, other negative is an error.
    private func roundTripOp(
        stackCap: Int,
        _ call: (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int>) -> Int32
    ) throws -> Data {
        var buf = [UInt8](repeating: 0, count: stackCap)
        var len: Int = stackCap
        var rc = buf.withUnsafeMutableBufferPointer { p -> Int32 in
            call(p.baseAddress, &len)
        }
        if rc == -2 {
            let needed = len
            buf = [UInt8](repeating: 0, count: needed)
            len = needed
            rc = buf.withUnsafeMutableBufferPointer { p -> Int32 in
                call(p.baseAddress, &len)
            }
        }
        if rc != 0 { throw EditorCoreError.crdtFailure(Self.lastError()) }
        return Data(buf.prefix(len))
    }

    private static func lastError() -> String {
        var buf = [UInt8](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBufferPointer { p -> Int in
            ct_last_error(p.baseAddress, p.count)
        }
        let copy = n > buf.count ? buf.count : n
        return String(bytes: buf.prefix(copy), encoding: .utf8) ?? ""
    }
}
