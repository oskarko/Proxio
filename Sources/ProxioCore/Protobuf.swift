import Foundation

/// One field of a schemaless protobuf message (wire format only: names and types come from a .proto, which is not known here).
public struct ProtoField: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }
    public let number: Int
    public let value: Value
}

public enum ProtobufDecoder {
    /// Parses `data` as a protobuf message. Returns nil unless the whole input is well-formed
    /// (valid tags, lengths inside the buffer, no groups, field numbers >= 1).
    public static func decode(_ data: Data) -> [ProtoField]? {
        let b = [UInt8](data)
        var i = 0
        var fields: [ProtoField] = []
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 70 {
                let byte = b[i]; i += 1
                if shift < 64 { result |= UInt64(byte & 0x7f) << shift }
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let tag = varint() else { return nil }
            let number = Int(truncatingIfNeeded: tag >> 3)
            guard number >= 1, tag >> 3 <= 0x1fff_ffff else { return nil }
            switch tag & 7 {
            case 0:
                guard let v = varint() else { return nil }
                fields.append(ProtoField(number: number, value: .varint(v)))
            case 1:
                guard i + 8 <= b.count else { return nil }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(b[i + k]) << UInt64(8 * k) }
                i += 8
                fields.append(ProtoField(number: number, value: .fixed64(v)))
            case 2:
                guard let len = varint(), len <= UInt64(b.count - i) else { return nil }
                fields.append(ProtoField(number: number, value: .bytes(Data(b[i..<i + Int(len)]))))
                i += Int(len)
            case 5:
                guard i + 4 <= b.count else { return nil }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(b[i + k]) << UInt32(8 * k) }
                i += 4
                fields.append(ProtoField(number: number, value: .fixed32(v)))
            default:
                return nil
            }
        }
        return fields.isEmpty ? nil : fields
    }

    /// Text in the style of `protoc --decode_raw`. Length-delimited fields are shown as a nested message
    /// when they parse as one, as a string when they are printable UTF-8, and as hex otherwise.
    public static func render(_ fields: [ProtoField], indent: Int = 0, depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        var lines: [String] = []
        for f in fields {
            switch f.value {
            case .varint(let v): lines.append("\(pad)\(f.number): \(v)")
            case .fixed64(let v): lines.append("\(pad)\(f.number): 0x\(String(v, radix: 16)) (fixed64)")
            case .fixed32(let v): lines.append("\(pad)\(f.number): 0x\(String(v, radix: 16)) (fixed32)")
            case .bytes(let d):
                if d.isEmpty {
                    lines.append("\(pad)\(f.number): \"\"")
                } else if let s = printable(d) {
                    lines.append("\(pad)\(f.number): \"\(s)\"")
                } else if depth < 8, let nested = decode(d) {
                    lines.append("\(pad)\(f.number) {")
                    lines.append(render(nested, indent: indent + 1, depth: depth + 1))
                    lines.append("\(pad)}")
                } else {
                    lines.append("\(pad)\(f.number): <\(d.count) bytes> " + d.prefix(32).map { String(format: "%02x", $0) }.joined() + (d.count > 32 ? "…" : ""))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func printable(_ d: Data) -> String? {
        guard let s = String(data: d, encoding: .utf8) else { return nil }
        for u in s.unicodeScalars where u.value < 0x20 && u != "\n" && u != "\t" { return nil }
        return s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }
}

/// gRPC length-prefixed messages (also gRPC-Web, where a trailers frame has the high flag bit set).
public enum GRPC {
    public struct Frame: Equatable, Sendable {
        public let isCompressed: Bool
        public let isTrailers: Bool
        public let payload: Data
    }

    public static func isGRPC(contentType: String?) -> Bool {
        guard let t = contentType?.lowercased() else { return false }
        return t.hasPrefix("application/grpc")
    }

    /// Splits `data` into frames. Returns nil if the framing is broken (a short header or a length past the end).
    public static func frames(from data: Data, contentType: String? = nil) -> [Frame]? {
        var data = data
        if contentType?.lowercased().hasPrefix("application/grpc-web-text") == true {
            guard let decoded = Data(base64Encoded: String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters) else { return nil }
            data = decoded
        }
        let b = [UInt8](data)
        var i = 0
        var out: [Frame] = []
        while i < b.count {
            guard i + 5 <= b.count else { return nil }
            let flag = b[i]
            guard flag & 0x7e == 0 else { return nil }
            let len = Int(b[i + 1]) << 24 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 8 | Int(b[i + 4])
            i += 5
            guard len <= b.count - i else { return nil }
            out.append(Frame(isCompressed: flag & 1 != 0, isTrailers: flag & 0x80 != 0, payload: Data(b[i..<i + len])))
            i += len
        }
        return out.isEmpty ? nil : out
    }

    /// Human-readable view of a gRPC body: one block per message, decoded as raw protobuf where possible.
    public static func render(_ data: Data, contentType: String?, messageType: String? = nil, schema: ProtoSchema? = nil) -> String? {
        guard let frames = frames(from: data, contentType: contentType) else { return nil }
        var blocks: [String] = []
        var n = 0
        func body(_ payload: Data) -> String? {
            if let t = messageType, let schema, let text = schema.render(payload, as: t) { return text }
            return ProtobufDecoder.decode(payload).map { ProtobufDecoder.render($0) }
        }
        for f in frames {
            if f.isTrailers {
                blocks.append("# trailers\n" + (String(data: f.payload, encoding: .utf8) ?? "<\(f.payload.count) bytes>"))
                continue
            }
            n += 1
            let header = "# message \(n)" + (f.isCompressed ? " (compressed, \(f.payload.count) bytes)" : "")
            if f.isCompressed {
                let inflated = ContentDecoder.decode(f.payload, encoding: "gzip")
                if let inflated, let text = body(inflated) {
                    blocks.append(header + "\n" + text)
                } else {
                    blocks.append(header + "\n" + BodyFormatter.hexDump(f.payload))
                }
            } else if f.payload.isEmpty {
                blocks.append(header + "\n(empty)")
            } else if let text = body(f.payload) {
                blocks.append(header + "\n" + text)
            } else {
                blocks.append(header + "\n" + BodyFormatter.hexDump(f.payload))
            }
        }
        return blocks.joined(separator: "\n\n")
    }
}

public extension BodyFormatter {
    /// Pretty text for gRPC and raw protobuf bodies, or nil for other content types.
    static func prettyProtobuf(_ data: Data, contentType: String?, grpcPath: String? = nil, isRequest: Bool = false) -> String? {
        if GRPC.isGRPC(contentType: contentType) {
            let schema = ProtoRegistry.shared.schema
            let method = grpcPath.flatMap { schema.methods[$0] }
            return GRPC.render(data, contentType: contentType, messageType: isRequest ? method?.input : method?.output, schema: schema)
        }
        guard let t = contentType?.lowercased(), t.contains("protobuf") || t.contains("x-protobuf") else { return nil }
        return ProtobufDecoder.decode(data).map { ProtobufDecoder.render($0) }
    }
}
