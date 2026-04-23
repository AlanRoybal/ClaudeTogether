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

struct RosterEntry: Equatable, Hashable {
    var identity: UserIdentity
    var role: SessionRole
    var color: UInt32
    var name: String
}

struct FsDelta: Equatable {
    enum Op: UInt8 {
        case upsert = 0
        case delete = 1
    }

    var op: Op
    /// Forward-slash relative path from the host's session root.
    var path: String
    /// Nanoseconds since Unix epoch; ignored for deletes.
    var mtimeNs: Int64
    /// Empty for deletes.
    var content: Data
}

enum Frame {
    case ptyOutput(Data)
    case inputOp(Data)
    case inputCommit(UserIdentity)
    case cursorPos(UserIdentity, col: UInt16, row: UInt16)
    case hello(UserIdentity, role: SessionRole, color: UInt32, name: String)
    case modeChange(TermMode)
    case roster([RosterEntry])
    case fsDelta(FsDelta)
    case heartbeat
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
        case .fsDelta(let delta):
            out.append(FrameTag.fsDelta.rawValue)
            out.append(delta.op.rawValue)
            let pathBytes = Array(delta.path.utf8)
            appendU16(&out, UInt16(min(pathBytes.count, Int(UInt16.max))))
            out.append(contentsOf: pathBytes.prefix(Int(UInt16.max)))
            appendI64(&out, delta.mtimeNs)
            appendU32(&out, UInt32(delta.content.count))
            out.append(delta.content)
        case .heartbeat:
            out.append(FrameTag.heartbeat.rawValue)
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
        case .fsDelta:
            let opByte = try r.readU8()
            guard let op = FsDelta.Op(rawValue: opByte) else {
                throw FrameCodecError.invalidEnum
            }
            let pathLen = try r.readU16()
            let pathBytes = try r.readBytes(Int(pathLen))
            let path = String(data: pathBytes, encoding: .utf8) ?? ""
            let mtime = try r.readI64()
            let contentLen = try r.readU32()
            let content = try r.readBytes(Int(contentLen))
            return .fsDelta(FsDelta(
                op: op,
                path: path,
                mtimeNs: mtime,
                content: content))
        case .heartbeat:
            return .heartbeat
        case .fsSnapshot:
            throw FrameCodecError.unsupportedTag
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

    private static func appendI64(_ d: inout Data, _ v: Int64) {
        let u = UInt64(bitPattern: v)
        d.append(UInt8((u >> 56) & 0xFF))
        d.append(UInt8((u >> 48) & 0xFF))
        d.append(UInt8((u >> 40) & 0xFF))
        d.append(UInt8((u >> 32) & 0xFF))
        d.append(UInt8((u >> 24) & 0xFF))
        d.append(UInt8((u >> 16) & 0xFF))
        d.append(UInt8((u >>  8) & 0xFF))
        d.append(UInt8( u        & 0xFF))
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

    mutating func readI64() throws -> Int64 {
        guard pos + 8 <= data.count else { throw FrameCodecError.truncated }
        let base = data.startIndex + pos
        // Split up per-byte so the type-checker doesn't choke on the
        // 8-term OR expression.
        var u: UInt64 = 0
        u |= UInt64(data[base])     << 56
        u |= UInt64(data[base + 1]) << 48
        u |= UInt64(data[base + 2]) << 40
        u |= UInt64(data[base + 3]) << 32
        u |= UInt64(data[base + 4]) << 24
        u |= UInt64(data[base + 5]) << 16
        u |= UInt64(data[base + 6]) <<  8
        u |= UInt64(data[base + 7])
        pos += 8
        return Int64(bitPattern: u)
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
