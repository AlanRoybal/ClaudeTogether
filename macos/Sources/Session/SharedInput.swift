import Foundation

enum SharedInputRequestKind: UInt8 {
    case insertText = 1
    case backspace  = 2
    case moveLeft   = 3
    case moveRight  = 4
    case moveHome   = 5
    case moveEnd    = 6
    case commit     = 7
    case interrupt  = 8
}

struct SharedInputRequest {
    var actor: UserIdentity
    var kind: SharedInputRequestKind
    var text: String = ""
}

struct SharedInputCursorState {
    var identity: UserIdentity
    var offset: Int
}

struct SharedInputSnapshot {
    var revision: UInt32
    var isActive: Bool
    var anchorCol: UInt16
    var anchorRow: UInt16
    var text: String
    var cursors: [SharedInputCursorState]
}

enum SharedInputPacket {
    case request(SharedInputRequest)
    case snapshot(SharedInputSnapshot)
}

enum SharedInputCodecError: Error {
    case invalidMagic
    case truncated
    case invalidEnum
    case invalidIdentity
}

enum SharedInputApplyEffect {
    case none
    case commit(String)
    case interrupt
}

enum SharedInputCodec {
    private static let magic: [UInt8] = [0x43, 0x54, 0x49] // "CTI"
    private static let requestTag: UInt8 = 1
    private static let snapshotTag: UInt8 = 2

    static func encode(_ packet: SharedInputPacket) -> Data {
        var out = Data(magic)
        switch packet {
        case .request(let req):
            out.append(requestTag)
            out.append(contentsOf: req.actor.bytes)
            out.append(req.kind.rawValue)
            if req.kind == .insertText {
                let utf8 = Array(req.text.utf8)
                appendU16(&out, UInt16(min(utf8.count, Int(UInt16.max))))
                out.append(contentsOf: utf8.prefix(Int(UInt16.max)))
            }
        case .snapshot(let snap):
            out.append(snapshotTag)
            appendU32(&out, snap.revision)
            out.append(snap.isActive ? 1 : 0)
            appendU16(&out, snap.anchorCol)
            appendU16(&out, snap.anchorRow)
            let utf8 = Array(snap.text.utf8)
            appendU16(&out, UInt16(min(utf8.count, Int(UInt16.max))))
            out.append(contentsOf: utf8.prefix(Int(UInt16.max)))
            appendU16(&out, UInt16(min(snap.cursors.count, Int(UInt16.max))))
            for cursor in snap.cursors.prefix(Int(UInt16.max)) {
                out.append(contentsOf: cursor.identity.bytes)
                appendU16(&out, UInt16(min(cursor.offset, Int(UInt16.max))))
            }
        }
        return out
    }

    static func decode(_ data: Data) throws -> SharedInputPacket {
        var r = SharedInputReader(data: data)
        let prefix = try r.readBytes(magic.count)
        guard Array(prefix) == magic else {
            throw SharedInputCodecError.invalidMagic
        }
        let tag = try r.readU8()
        switch tag {
        case requestTag:
            let actor = try UserIdentity.sharedInputFrom(exactly16:
                Array(try r.readBytes(16)))
            let kindByte = try r.readU8()
            guard let kind = SharedInputRequestKind(rawValue: kindByte) else {
                throw SharedInputCodecError.invalidEnum
            }
            var text = ""
            if kind == .insertText {
                let textLen = try r.readU16()
                text = String(data: try r.readBytes(Int(textLen)),
                              encoding: .utf8) ?? ""
            }
            return .request(SharedInputRequest(actor: actor, kind: kind, text: text))
        case snapshotTag:
            let revision = try r.readU32()
            let isActive = try r.readU8() != 0
            let anchorCol = try r.readU16()
            let anchorRow = try r.readU16()
            let textLen = try r.readU16()
            let text = String(data: try r.readBytes(Int(textLen)),
                              encoding: .utf8) ?? ""
            let cursorCount = try r.readU16()
            var cursors: [SharedInputCursorState] = []
            cursors.reserveCapacity(Int(cursorCount))
            for _ in 0..<Int(cursorCount) {
                let identity = try UserIdentity.sharedInputFrom(exactly16:
                    Array(try r.readBytes(16)))
                let offset = Int(try r.readU16())
                cursors.append(SharedInputCursorState(
                    identity: identity,
                    offset: offset))
            }
            return .snapshot(SharedInputSnapshot(
                revision: revision,
                isActive: isActive,
                anchorCol: anchorCol,
                anchorRow: anchorRow,
                text: text,
                cursors: cursors))
        default:
            throw SharedInputCodecError.invalidEnum
        }
    }

    private static func appendU16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8(v & 0xFF))
    }

    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8(v & 0xFF))
    }
}

struct SharedInputState {
    private(set) var revision: UInt32 = 0
    private(set) var isActive: Bool = false
    private(set) var anchorCol: UInt16 = 0
    private(set) var anchorRow: UInt16 = 0
    private(set) var textScalars: [UnicodeScalar] = []
    private(set) var cursors: [UserIdentity: Int] = [:]

    var text: String {
        textScalars.map(String.init).joined()
    }

    mutating func activate(anchorCol: UInt16,
                           anchorRow: UInt16,
                           participants: [UserIdentity],
                           bumpRevision: Bool = true) -> Bool
    {
        var changed = !isActive || self.anchorCol != anchorCol || self.anchorRow != anchorRow
        isActive = true
        self.anchorCol = anchorCol
        self.anchorRow = anchorRow
        if syncParticipants(participants) {
            changed = true
        }
        if changed && bumpRevision {
            revision &+= 1
        }
        return changed
    }

    mutating func deactivate(bumpRevision: Bool = true) -> Bool {
        let hadState = isActive || !textScalars.isEmpty || !cursors.isEmpty
        isActive = false
        textScalars.removeAll(keepingCapacity: true)
        cursors.removeAll(keepingCapacity: true)
        if hadState && bumpRevision {
            revision &+= 1
        }
        return hadState
    }

    mutating func syncParticipants(_ participants: [UserIdentity],
                                   bumpRevision: Bool = true) -> Bool
    {
        let clampedEnd = textScalars.count
        var next: [UserIdentity: Int] = [:]
        var changed = false
        for identity in participants {
            guard next[identity] == nil else { continue }
            let cursor = clamp(cursors[identity] ?? clampedEnd, max: clampedEnd)
            next[identity] = cursor
            if cursors[identity] != cursor {
                changed = true
            }
        }
        if next.count != cursors.count {
            changed = true
        }
        if changed {
            cursors = next
            if bumpRevision {
                revision &+= 1
            }
        }
        return changed
    }

    mutating func apply(_ request: SharedInputRequest,
                        bumpRevision: Bool = true) -> SharedInputApplyEffect
    {
        guard isActive else { return .none }
        guard var cursor = cursors[request.actor] else { return .none }

        switch request.kind {
        case .insertText:
            let incoming = Array(request.text.unicodeScalars)
            guard !incoming.isEmpty else { return .none }
            cursor = clamp(cursor, max: textScalars.count)
            textScalars.insert(contentsOf: incoming, at: cursor)
            shiftOtherCursors(startingAt: cursor, delta: incoming.count, except: request.actor)
            cursors[request.actor] = cursor + incoming.count
        case .backspace:
            cursor = clamp(cursor, max: textScalars.count)
            guard cursor > 0 else { return .none }
            let deleteIndex = cursor - 1
            textScalars.remove(at: deleteIndex)
            shiftOtherCursors(startingAt: deleteIndex + 1, delta: -1, except: request.actor)
            cursors[request.actor] = deleteIndex
        case .moveLeft:
            cursors[request.actor] = max(0, cursor - 1)
        case .moveRight:
            cursors[request.actor] = min(textScalars.count, cursor + 1)
        case .moveHome:
            cursors[request.actor] = 0
        case .moveEnd:
            cursors[request.actor] = textScalars.count
        case .commit:
            let committed = text
            _ = deactivate(bumpRevision: bumpRevision)
            return .commit(committed)
        case .interrupt:
            _ = deactivate(bumpRevision: bumpRevision)
            return .interrupt
        }

        if bumpRevision {
            revision &+= 1
        }
        return .none
    }

    mutating func apply(_ snapshot: SharedInputSnapshot) {
        revision = snapshot.revision
        isActive = snapshot.isActive
        anchorCol = snapshot.anchorCol
        anchorRow = snapshot.anchorRow
        textScalars = Array(snapshot.text.unicodeScalars)
        cursors.removeAll(keepingCapacity: true)
        for cursor in snapshot.cursors {
            self.cursors[cursor.identity] = clamp(cursor.offset, max: textScalars.count)
        }
    }

    func snapshot(participants: [UserIdentity]) -> SharedInputSnapshot {
        let activeCursors: [SharedInputCursorState]
        if isActive {
            activeCursors = participants.compactMap { identity in
                guard let offset = cursors[identity] else { return nil }
                return SharedInputCursorState(
                    identity: identity,
                    offset: clamp(offset, max: textScalars.count))
            }
        } else {
            activeCursors = []
        }
        return SharedInputSnapshot(
            revision: revision,
            isActive: isActive,
            anchorCol: anchorCol,
            anchorRow: anchorRow,
            text: isActive ? text : "",
            cursors: activeCursors)
    }

    private mutating func shiftOtherCursors(startingAt threshold: Int,
                                            delta: Int,
                                            except actor: UserIdentity)
    {
        guard delta != 0 else { return }
        for (identity, cursor) in cursors where identity != actor {
            if cursor >= threshold {
                cursors[identity] = max(0, cursor + delta)
            }
        }
    }

    private func clamp(_ value: Int, max upperBound: Int) -> Int {
        Swift.max(0, Swift.min(upperBound, value))
    }
}

private struct SharedInputReader {
    let data: Data
    var pos: Int = 0

    mutating func readU8() throws -> UInt8 {
        guard pos + 1 <= data.count else { throw SharedInputCodecError.truncated }
        let v = data[data.startIndex + pos]
        pos += 1
        return v
    }

    mutating func readU16() throws -> UInt16 {
        guard pos + 2 <= data.count else { throw SharedInputCodecError.truncated }
        let b0 = data[data.startIndex + pos]
        let b1 = data[data.startIndex + pos + 1]
        pos += 2
        return (UInt16(b0) << 8) | UInt16(b1)
    }

    mutating func readU32() throws -> UInt32 {
        guard pos + 4 <= data.count else { throw SharedInputCodecError.truncated }
        let base = data.startIndex + pos
        let v =
            (UInt32(data[base])     << 24) |
            (UInt32(data[base + 1]) << 16) |
            (UInt32(data[base + 2]) << 8)  |
             UInt32(data[base + 3])
        pos += 4
        return v
    }

    mutating func readBytes(_ n: Int) throws -> Data {
        guard pos + n <= data.count else { throw SharedInputCodecError.truncated }
        let start = data.startIndex + pos
        let slice = data.subdata(in: start ..< (start + n))
        pos += n
        return slice
    }
}

extension UserIdentity {
    var uuidValue: UUID {
        UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    fileprivate static func sharedInputFrom(exactly16 bytes: [UInt8]) throws -> UserIdentity {
        guard bytes.count == 16 else { throw SharedInputCodecError.invalidIdentity }
        return UserIdentity(bytes: bytes)
    }
}
