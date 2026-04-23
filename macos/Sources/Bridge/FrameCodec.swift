import Foundation

/// Swift mirror of `core/src/frame.zig`. The zig side ships opaque bytes
/// through `ct_session_{broadcast,poll}`; both ends encode/decode with
/// the same layout (big-endian, length-prefixed blobs).
enum FrameTag: UInt8 {
    case ptyOutput   = 0x01
    case inputOp     = 0x02
    case inputCommit = 0x03
    case fsDelta     = 0x04
    case fsSnapshot  = 0x05
    case cursorPos   = 0x06
    case hello       = 0x07
    case modeChange  = 0x08
    case roster      = 0x09
    case heartbeat   = 0x0A
    // Collaborative editor frames (0x10..0x15). Tags start at 0x10 to leave
    // room above the core session frames; must match `Tag` in frame.zig.
    case editorOpen      = 0x10
    case editorOp        = 0x11
    case editorPresence  = 0x12
    case editorSave      = 0x13
    case editorSaved     = 0x14
    case editorClose     = 0x15
}

enum SessionRole: UInt8 {
    case host = 0
    case peer = 1
}

enum TermMode: UInt8 {
    case line = 0
    case raw  = 1
}

typealias UserID = (UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8)

struct UserIdentity: Equatable, Hashable {
    var bytes: [UInt8] // always 16

    static func random() -> UserIdentity {
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { b[i] = UInt8.random(in: 0...255) }
        return UserIdentity(bytes: b)
    }

    static func == (l: UserIdentity, r: UserIdentity) -> Bool {
        return l.bytes == r.bytes
    }

    func hash(into h: inout Hasher) { h.combine(bytes) }
}

/// Stable cursor anchor id. Mirrors `crdt.Id` in core/src/crdt.zig as a
/// `client:u32 clock:u32` pair.
struct CrdtId: Equatable, Hashable {
    var client: UInt32
    var clock: UInt32
}

struct RosterEntry: Equatable, Hashable {
    var identity: UserIdentity
    var role: SessionRole
    var color: UInt32
    var name: String
}

enum FSSyncDeltaKind: UInt8 {
    case upsertFile      = 0
    case ensureDirectory = 1
    case deletePath      = 2
}

enum FSSnapshotEntryKind: UInt8, Codable {
    case file      = 0
    case directory = 1
}

struct FSSyncDelta: Equatable {
    var kind: FSSyncDeltaKind
    var path: String
    var data: Data = Data()
}

struct FSSnapshotEntry: Equatable, Hashable, Codable {
    var kind: FSSnapshotEntryKind
    var path: String
}

enum Frame {
    case ptyOutput(Data)
    case inputOp(Data)
    case inputCommit(UserIdentity)
    case fsDelta(FSSyncDelta)
    case fsSnapshot([FSSnapshotEntry])
    case cursorPos(UserIdentity, col: UInt16, row: UInt16)
    case hello(UserIdentity, role: SessionRole, color: UInt32, name: String)
    case modeChange(TermMode)
    case roster([RosterEntry])
    case heartbeat
    case editorOpen(docId: UInt64, path: String, snapshot: Data)
    case editorOp(docId: UInt64, opBytes: Data)
    case editorPresence(docId: UInt64, userId: UInt32,
                        anchor: CrdtId?, selectionAnchor: CrdtId?)
    case editorSave(docId: UInt64)
    case editorSaved(docId: UInt64, rev: UInt32)
    case editorClose(docId: UInt64)
}

enum FrameCodecError: Error {
    case truncated
    case unknownTag
    case invalidEnum
    case unsupportedTag
}

enum FrameCodec {
    // MARK: encode

    static func encode(_ frame: Frame) -> Data {
        var out = Data()
        switch frame {
        case .ptyOutput(let d):
            out.append(FrameTag.ptyOutput.rawValue)
            appendU32(&out, UInt32(d.count))
            out.append(d)
        case .inputOp(let d):
            out.append(FrameTag.inputOp.rawValue)
            appendU32(&out, UInt32(d.count))
            out.append(d)
        case .inputCommit(let id):
            out.append(FrameTag.inputCommit.rawValue)
            out.append(contentsOf: id.bytes)
        case .fsDelta(let payload):
            out.append(FrameTag.fsDelta.rawValue)
            out.append(payload.kind.rawValue)
            let pathUtf8 = Array(payload.path.utf8)
            appendU16(&out, UInt16(min(pathUtf8.count, Int(UInt16.max))))
            out.append(contentsOf: pathUtf8.prefix(Int(UInt16.max)))
            appendU32(&out, UInt32(payload.data.count))
            out.append(payload.data)
        case .fsSnapshot(let entries):
            out.append(FrameTag.fsSnapshot.rawValue)
            appendU32(&out, UInt32(min(entries.count, Int(UInt32.max))))
            for entry in entries.prefix(Int(UInt32.max)) {
                out.append(entry.kind.rawValue)
                let pathUtf8 = Array(entry.path.utf8)
                appendU16(&out, UInt16(min(pathUtf8.count, Int(UInt16.max))))
                out.append(contentsOf: pathUtf8.prefix(Int(UInt16.max)))
            }
        case .cursorPos(let id, let col, let row):
            out.append(FrameTag.cursorPos.rawValue)
            out.append(contentsOf: id.bytes)
            appendU16(&out, col)
            appendU16(&out, row)
        case .hello(let id, let role, let color, let name):
            out.append(FrameTag.hello.rawValue)
            out.append(contentsOf: id.bytes)
            out.append(role.rawValue)
            appendU32(&out, color)
            let utf8 = Array(name.utf8)
            appendU16(&out, UInt16(min(utf8.count, Int(UInt16.max))))
            out.append(contentsOf: utf8.prefix(Int(UInt16.max)))
        case .modeChange(let m):
            out.append(FrameTag.modeChange.rawValue)
            out.append(m.rawValue)
        case .roster(let entries):
            out.append(FrameTag.roster.rawValue)
            appendU16(&out, UInt16(min(entries.count, Int(UInt16.max))))
            for e in entries.prefix(Int(UInt16.max)) {
                out.append(contentsOf: e.identity.bytes)
                out.append(e.role.rawValue)
                appendU32(&out, e.color)
                let utf8 = Array(e.name.utf8)
                appendU16(&out, UInt16(min(utf8.count, Int(UInt16.max))))
                out.append(contentsOf: utf8.prefix(Int(UInt16.max)))
            }
        case .heartbeat:
            out.append(FrameTag.heartbeat.rawValue)
        case .editorOpen(let docId, let path, let snapshot):
            out.append(FrameTag.editorOpen.rawValue)
            appendU64(&out, docId)
            let pathUtf8 = Array(path.utf8)
            appendU16(&out, UInt16(min(pathUtf8.count, Int(UInt16.max))))
            out.append(contentsOf: pathUtf8.prefix(Int(UInt16.max)))
            appendU32(&out, UInt32(snapshot.count))
            out.append(snapshot)
        case .editorOp(let docId, let opBytes):
            out.append(FrameTag.editorOp.rawValue)
            appendU64(&out, docId)
            appendU32(&out, UInt32(opBytes.count))
            out.append(opBytes)
        case .editorPresence(let docId, let userId, let anchor, let sel):
            out.append(FrameTag.editorPresence.rawValue)
            appendU64(&out, docId)
            appendU32(&out, userId)
            appendOptCrdtId(&out, anchor)
            appendOptCrdtId(&out, sel)
        case .editorSave(let docId):
            out.append(FrameTag.editorSave.rawValue)
            appendU64(&out, docId)
        case .editorSaved(let docId, let rev):
            out.append(FrameTag.editorSaved.rawValue)
            appendU64(&out, docId)
            appendU32(&out, rev)
        case .editorClose(let docId):
            out.append(FrameTag.editorClose.rawValue)
            appendU64(&out, docId)
        }
        return out
    }

    // MARK: decode

    static func decode(_ data: Data) throws -> Frame {
        var r = Reader(data: data)
        let tagByte = try r.readU8()
        guard let tag = FrameTag(rawValue: tagByte) else {
            throw FrameCodecError.unknownTag
        }
        switch tag {
        case .ptyOutput:
            let n = try r.readU32()
            let payload = try r.readBytes(Int(n))
            return .ptyOutput(payload)
        case .inputOp:
            let n = try r.readU32()
            return .inputOp(try r.readBytes(Int(n)))
        case .inputCommit:
            let id = try UserIdentity.from(exactly16: Array(try r.readBytes(16)))
            return .inputCommit(id)
        case .fsDelta:
            let kindByte = try r.readU8()
            guard let kind = FSSyncDeltaKind(rawValue: kindByte) else {
                throw FrameCodecError.invalidEnum
            }
            let pathLen = try r.readU16()
            let pathBytes = try r.readBytes(Int(pathLen))
            let path = String(data: pathBytes, encoding: .utf8) ?? ""
            let dataLen = try r.readU32()
            let payload = try r.readBytes(Int(dataLen))
            return .fsDelta(FSSyncDelta(kind: kind, path: path, data: payload))
        case .fsSnapshot:
            let count = try r.readU32()
            var entries: [FSSnapshotEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                let kindByte = try r.readU8()
                guard let kind = FSSnapshotEntryKind(rawValue: kindByte) else {
                    throw FrameCodecError.invalidEnum
                }
                let pathLen = try r.readU16()
                let pathBytes = try r.readBytes(Int(pathLen))
                let path = String(data: pathBytes, encoding: .utf8) ?? ""
                entries.append(FSSnapshotEntry(kind: kind, path: path))
            }
            return .fsSnapshot(entries)
        case .cursorPos:
            let id = try UserIdentity.from(exactly16: Array(try r.readBytes(16)))
            let col = try r.readU16()
            let row = try r.readU16()
            return .cursorPos(id, col: col, row: row)
        case .hello:
            let id = try UserIdentity.from(exactly16: Array(try r.readBytes(16)))
            let roleByte = try r.readU8()
            guard let role = SessionRole(rawValue: roleByte) else {
                throw FrameCodecError.invalidEnum
            }
            let color = try r.readU32()
            let nameLen = try r.readU16()
            let nameBytes = try r.readBytes(Int(nameLen))
            let name = String(data: nameBytes, encoding: .utf8) ?? ""
            return .hello(id, role: role, color: color, name: name)
        case .modeChange:
            let mByte = try r.readU8()
            guard let mode = TermMode(rawValue: mByte) else {
                throw FrameCodecError.invalidEnum
            }
            return .modeChange(mode)
        case .roster:
            let count = try r.readU16()
            var entries: [RosterEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                let id = try UserIdentity.from(exactly16:
                    Array(try r.readBytes(16)))
                let roleByte = try r.readU8()
                guard let role = SessionRole(rawValue: roleByte) else {
                    throw FrameCodecError.invalidEnum
                }
                let color = try r.readU32()
                let nameLen = try r.readU16()
                let nameBytes = try r.readBytes(Int(nameLen))
                let name = String(data: nameBytes, encoding: .utf8) ?? ""
                entries.append(RosterEntry(
                    identity: id, role: role, color: color, name: name))
            }
            return .roster(entries)
        case .heartbeat:
            return .heartbeat
        case .editorOpen:
            let docId = try r.readU64()
            let pathLen = try r.readU16()
            let pathBytes = try r.readBytes(Int(pathLen))
            let path = String(data: pathBytes, encoding: .utf8) ?? ""
            let snapLen = try r.readU32()
            let snapshot = try r.readBytes(Int(snapLen))
            return .editorOpen(docId: docId, path: path, snapshot: snapshot)
        case .editorOp:
            let docId = try r.readU64()
            let n = try r.readU32()
            let opBytes = try r.readBytes(Int(n))
            return .editorOp(docId: docId, opBytes: opBytes)
        case .editorPresence:
            let docId = try r.readU64()
            let userId = try r.readU32()
            let anchor = try r.readOptCrdtId()
            let sel = try r.readOptCrdtId()
            return .editorPresence(docId: docId, userId: userId,
                                   anchor: anchor, selectionAnchor: sel)
        case .editorSave:
            let docId = try r.readU64()
            return .editorSave(docId: docId)
        case .editorSaved:
            let docId = try r.readU64()
            let rev = try r.readU32()
            return .editorSaved(docId: docId, rev: rev)
        case .editorClose:
            let docId = try r.readU64()
            return .editorClose(docId: docId)
        }
    }

    // MARK: helpers

    private static func appendU16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8(v & 0xFF))
    }

    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >>  8) & 0xFF))
        d.append(UInt8( v        & 0xFF))
    }

    private static func appendU64(_ d: inout Data, _ v: UInt64) {
        d.append(UInt8((v >> 56) & 0xFF))
        d.append(UInt8((v >> 48) & 0xFF))
        d.append(UInt8((v >> 40) & 0xFF))
        d.append(UInt8((v >> 32) & 0xFF))
        d.append(UInt8((v >> 24) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >>  8) & 0xFF))
        d.append(UInt8( v        & 0xFF))
    }

    private static func appendOptCrdtId(_ d: inout Data, _ v: CrdtId?) {
        if let id = v {
            d.append(UInt8(1))
            appendU32(&d, id.client)
            appendU32(&d, id.clock)
        } else {
            d.append(UInt8(0))
        }
    }
}

private struct Reader {
    let data: Data
    var pos: Int = 0

    mutating func readU8() throws -> UInt8 {
        guard pos + 1 <= data.count else { throw FrameCodecError.truncated }
        let v = data[data.startIndex + pos]
        pos += 1
        return v
    }

    mutating func readU16() throws -> UInt16 {
        guard pos + 2 <= data.count else { throw FrameCodecError.truncated }
        let b0 = data[data.startIndex + pos]
        let b1 = data[data.startIndex + pos + 1]
        pos += 2
        return (UInt16(b0) << 8) | UInt16(b1)
    }

    mutating func readU32() throws -> UInt32 {
        guard pos + 4 <= data.count else { throw FrameCodecError.truncated }
        let base = data.startIndex + pos
        let v =
            (UInt32(data[base])     << 24) |
            (UInt32(data[base + 1]) << 16) |
            (UInt32(data[base + 2]) <<  8) |
             UInt32(data[base + 3])
        pos += 4
        return v
    }

    mutating func readU64() throws -> UInt64 {
        guard pos + 8 <= data.count else { throw FrameCodecError.truncated }
        let base = data.startIndex + pos
        let hi: UInt64 =
            (UInt64(data[base])     << 24) |
            (UInt64(data[base + 1]) << 16) |
            (UInt64(data[base + 2]) <<  8) |
             UInt64(data[base + 3])
        let lo: UInt64 =
            (UInt64(data[base + 4]) << 24) |
            (UInt64(data[base + 5]) << 16) |
            (UInt64(data[base + 6]) <<  8) |
             UInt64(data[base + 7])
        pos += 8
        return (hi << 32) | lo
    }

    mutating func readOptCrdtId() throws -> CrdtId? {
        let has = try readU8()
        if has == 0 { return nil }
        guard has == 1 else { throw FrameCodecError.invalidEnum }
        let client = try readU32()
        let clock = try readU32()
        return CrdtId(client: client, clock: clock)
    }

    mutating func readBytes(_ n: Int) throws -> Data {
        guard pos + n <= data.count else { throw FrameCodecError.truncated }
        let start = data.startIndex + pos
        let slice = data.subdata(in: start ..< (start + n))
        pos += n
        return slice
    }
}

private extension UserIdentity {
    static func from(exactly16 bytes: [UInt8]) throws -> UserIdentity {
        guard bytes.count == 16 else { throw FrameCodecError.truncated }
        return UserIdentity(bytes: bytes)
    }
}
