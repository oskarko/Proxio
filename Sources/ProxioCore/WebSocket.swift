import Foundation

/// One WebSocket message observed on an upgraded connection.
public struct WebSocketMessage: Sendable, Identifiable, Equatable, Codable {
    public enum Direction: String, Sendable, Codable { case sent, received }
    public enum Kind: String, Sendable, Codable { case text, binary, close, ping, pong }

    public let id: UUID
    public var timestamp: Date
    public var direction: Direction
    public var kind: Kind
    /// At most `WebSocketFrameParser.maxStoredPayload` bytes; `size` is the real length.
    public var payload: Data
    public var size: Int

    public init(id: UUID = UUID(), timestamp: Date = Date(), direction: Direction, kind: Kind, payload: Data, size: Int? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.kind = kind
        self.payload = payload
        self.size = size ?? payload.count
    }

    /// UTF-8 text for text frames, the status code and reason for close frames.
    public var text: String? {
        switch kind {
        case .text, .ping, .pong:
            return String(data: payload, encoding: .utf8)
        case .close:
            guard payload.count >= 2 else { return "" }
            let code = Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1])
            let reason = String(data: payload.dropFirst(2), encoding: .utf8) ?? ""
            return reason.isEmpty ? "\(code)" : "\(code) \(reason)"
        case .binary:
            return nil
        }
    }

    public var isTruncated: Bool { payload.count < size }
}

/// Incremental RFC 6455 frame reader. It only observes: the bytes it is fed are
/// still relayed untouched, so a parse problem never breaks the connection.
public struct WebSocketFrameParser: Sendable {
    public static let maxStoredPayload = 1_048_576
    public static let maxFrameSize = 64 * 1_048_576

    public let direction: WebSocketMessage.Direction
    /// Set once a frame is malformed or too large; later bytes are ignored.
    public private(set) var isDisabled = false

    private var buffer: [UInt8] = []
    private var fragments = Data()
    private var fragmentSize = 0
    private var fragmentKind: WebSocketMessage.Kind?

    public init(direction: WebSocketMessage.Direction) { self.direction = direction }

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [WebSocketMessage] {
        guard !isDisabled else { return [] }
        buffer.append(contentsOf: bytes)
        var messages: [WebSocketMessage] = []
        var offset = 0
        parsing: while let frame = nextFrame(at: &offset) {
            switch frame.opcode {
            case 0x0:
                guard let kind = fragmentKind else { isDisabled = true; break parsing }
                append(frame.payload, size: frame.size)
                if frame.fin {
                    messages.append(message(kind, fragments, size: fragmentSize))
                    fragmentKind = nil; fragments = Data(); fragmentSize = 0
                }
            case 0x1, 0x2:
                let kind: WebSocketMessage.Kind = frame.opcode == 0x1 ? .text : .binary
                if frame.fin {
                    messages.append(message(kind, Data(frame.payload), size: frame.size))
                } else {
                    fragmentKind = kind; fragments = Data(); fragmentSize = 0
                    append(frame.payload, size: frame.size)
                }
            case 0x8: messages.append(message(.close, Data(frame.payload), size: frame.size))
            case 0x9: messages.append(message(.ping, Data(frame.payload), size: frame.size))
            case 0xA: messages.append(message(.pong, Data(frame.payload), size: frame.size))
            default: isDisabled = true; break parsing
            }
        }
        buffer.removeFirst(min(offset, buffer.count))
        if isDisabled { buffer = [] }
        return messages
    }

    private mutating func append(_ payload: [UInt8], size: Int) {
        fragmentSize += size
        let room = Self.maxStoredPayload - fragments.count
        if room > 0 { fragments.append(contentsOf: payload.prefix(room)) }
    }

    private func message(_ kind: WebSocketMessage.Kind, _ payload: Data, size: Int) -> WebSocketMessage {
        WebSocketMessage(direction: direction, kind: kind, payload: payload.prefix(Self.maxStoredPayload), size: size)
    }

    private struct Frame { let fin: Bool; let opcode: UInt8; let payload: [UInt8]; let size: Int }

    private mutating func nextFrame(at offset: inout Int) -> Frame? {
        let b = buffer
        var i = offset
        guard b.count - i >= 2 else { return nil }
        let fin = b[i] & 0x80 != 0
        let opcode = b[i] & 0x0F
        let masked = b[i + 1] & 0x80 != 0
        var length = Int(b[i + 1] & 0x7F)
        i += 2
        if length == 126 {
            guard b.count - i >= 2 else { return nil }
            length = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
        } else if length == 127 {
            guard b.count - i >= 8 else { return nil }
            var wide: UInt64 = 0
            for k in 0..<8 { wide = wide << 8 | UInt64(b[i + k]) }
            guard wide <= UInt64(Self.maxFrameSize) else { isDisabled = true; return nil }
            length = Int(wide); i += 8
        }
        guard length <= Self.maxFrameSize else { isDisabled = true; return nil }
        var key: [UInt8] = []
        if masked {
            guard b.count - i >= 4 else { return nil }
            key = Array(b[i..<i + 4]); i += 4
        }
        guard b.count - i >= length else { return nil }
        var payload = Array(b[i..<i + length])
        if masked { for k in payload.indices { payload[k] ^= key[k & 3] } }
        offset = i + length
        return Frame(fin: fin, opcode: opcode, payload: payload, size: length)
    }
}

public enum WebSocketFrame {
    /// Encodes a single final frame. Clients must mask (pass a 4-byte `maskKey`).
    public static func encode(opcode: UInt8, payload: Data, maskKey: [UInt8]? = nil) -> Data {
        var out = Data([0x80 | opcode])
        let maskBit: UInt8 = maskKey == nil ? 0 : 0x80
        switch payload.count {
        case 0..<126: out.append(maskBit | UInt8(payload.count))
        case 126..<65_536:
            out.append(maskBit | 126)
            out.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default:
            out.append(maskBit | 127)
            out.append(contentsOf: (0..<8).map { UInt8((payload.count >> (8 * (7 - $0))) & 0xFF) })
        }
        if let maskKey {
            out.append(contentsOf: maskKey)
            out.append(contentsOf: payload.enumerated().map { $0.element ^ maskKey[$0.offset & 3] })
        } else {
            out.append(payload)
        }
        return out
    }
}
