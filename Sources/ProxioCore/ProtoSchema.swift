import Foundation

/// A parsed `.proto` file set: enough of proto2/proto3 to name and type the fields of a message
/// (messages, nested types, enums, oneofs, maps, services). Options, extensions and reserved ranges are skipped.
public struct ProtoSchema: Sendable {
    public struct Field: Sendable {
        public let name: String
        public let number: Int
        public let type: String          // scalar name or (possibly relative) message/enum name
        public let repeated: Bool
        public let mapKey: String?       // set for map<K, V>; `type` is then V
    }
    public struct Message: Sendable {
        public let fullName: String
        public var fields: [Int: Field] = [:]
    }
    public struct Enum: Sendable {
        public let fullName: String
        public var values: [Int: String] = [:]
    }
    public struct Method: Sendable, Equatable {
        public let input: String         // fully qualified
        public let output: String
    }

    public private(set) var messages: [String: Message] = [:]
    public private(set) var enums: [String: Enum] = [:]
    /// Keyed by gRPC path `/package.Service/Method`.
    public private(set) var methods: [String: Method] = [:]

    public init() {}

    public var isEmpty: Bool { messages.isEmpty && methods.isEmpty }

    /// Parses one file and merges it into the schema. Returns false when the text is not valid enough to parse.
    @discardableResult
    public mutating func add(source: String) -> Bool {
        var p = Parser(tokens: Tokenizer.tokens(source))
        guard p.parseFile() else { return false }
        for m in p.messages { messages[m.fullName] = m }
        for e in p.enums { enums[e.fullName] = e }
        for (path, m) in p.methods { methods[path] = m }
        return true
    }

    /// Resolves `name` as seen from inside `scope` (a full message name), the way protoc does: innermost scope first.
    func resolve(_ name: String, from scope: String) -> String? {
        if name.hasPrefix(".") { let n = String(name.dropFirst()); return messages[n] != nil || enums[n] != nil ? n : nil }
        var parts = scope.split(separator: ".").map(String.init)
        while true {
            let candidate = (parts + [name]).joined(separator: ".")
            if messages[candidate] != nil || enums[candidate] != nil { return candidate }
            if parts.isEmpty { return nil }
            parts.removeLast()
        }
    }

    // MARK: Rendering

    /// Text-format rendering of `data` as message `type` (full name). Nil when the bytes are not a well-formed message.
    public func render(_ data: Data, as type: String) -> String? {
        guard messages[type] != nil, let fields = ProtobufDecoder.decode(data) else { return data.isEmpty ? "" : nil }
        return render(fields, type: type, indent: 0, depth: 0)
    }

    private func render(_ fields: [ProtoField], type: String, indent: Int, depth: Int) -> String {
        guard let message = messages[type] else { return ProtobufDecoder.render(fields, indent: indent) }
        let pad = String(repeating: "  ", count: indent)
        var lines: [String] = []
        for f in fields {
            guard let def = message.fields[f.number] else {
                lines.append(ProtobufDecoder.render([f], indent: indent))
                continue
            }
            let values = expand(f, def: def)
            if values.isEmpty { lines.append(ProtobufDecoder.render([f], indent: indent)); continue }
            for v in values {
                lines.append(line(def.name, v, def: def, scope: type, pad: pad, indent: indent, depth: depth))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One field occurrence can carry several values (packed repeated scalars).
    private func expand(_ f: ProtoField, def: Field) -> [ProtoField.Value] {
        if case .bytes(let d) = f.value, def.repeated, def.mapKey == nil, let w = Self.packedWire(def.type) {
            var out: [ProtoField.Value] = []
            switch w {
            case 0:
                let b = [UInt8](d); var i = 0
                while i < b.count {
                    var r: UInt64 = 0, s: UInt64 = 0
                    while i < b.count, s < 70 { let x = b[i]; i += 1; if s < 64 { r |= UInt64(x & 0x7f) << s }; if x & 0x80 == 0 { break }; s += 7 }
                    out.append(.varint(r))
                }
            case 1:
                guard d.count % 8 == 0 else { return [f.value] }
                let b = [UInt8](d)
                for o in stride(from: 0, to: b.count, by: 8) { out.append(.fixed64((0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << UInt64(8 * $1) })) }
            default:
                guard d.count % 4 == 0 else { return [f.value] }
                let b = [UInt8](d)
                for o in stride(from: 0, to: b.count, by: 4) { out.append(.fixed32((0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << UInt32(8 * $1) })) }
            }
            return out
        }
        return [f.value]
    }

    private static func packedWire(_ type: String) -> Int? {
        switch type {
        case "int32", "int64", "uint32", "uint64", "sint32", "sint64", "bool": return 0
        case "fixed64", "sfixed64", "double": return 1
        case "fixed32", "sfixed32", "float": return 5
        default: return nil   // enums are resolved by the caller, packed enums fall back to raw
        }
    }

    private func line(_ name: String, _ value: ProtoField.Value, def: Field, scope: String, pad: String, indent: Int, depth: Int) -> String {
        let raw = { ProtobufDecoder.render([ProtoField(number: def.number, value: value)], indent: indent) }
        let type = def.type
        switch value {
        case .varint(let v):
            switch type {
            case "int32": return "\(pad)\(name): \(Int32(truncatingIfNeeded: v))"
            case "int64": return "\(pad)\(name): \(Int64(bitPattern: v))"
            case "uint32": return "\(pad)\(name): \(UInt32(truncatingIfNeeded: v))"
            case "uint64": return "\(pad)\(name): \(v)"
            case "sint32": let n = UInt32(truncatingIfNeeded: v); return "\(pad)\(name): \(Int32(bitPattern: n >> 1) ^ -Int32(bitPattern: n & 1))"
            case "sint64": return "\(pad)\(name): \(Int64(bitPattern: v >> 1) ^ -Int64(bitPattern: v & 1))"
            case "bool": return "\(pad)\(name): \(v != 0)"
            default:
                if let full = resolve(type, from: scope), let e = enums[full] {
                    return "\(pad)\(name): \(e.values[Int(Int32(truncatingIfNeeded: v))] ?? String(Int32(truncatingIfNeeded: v)))"
                }
                return raw()
            }
        case .fixed32(let v):
            switch type {
            case "float": return "\(pad)\(name): \(Float(bitPattern: v))"
            case "fixed32": return "\(pad)\(name): \(v)"
            case "sfixed32": return "\(pad)\(name): \(Int32(bitPattern: v))"
            default: return raw()
            }
        case .fixed64(let v):
            switch type {
            case "double": return "\(pad)\(name): \(Double(bitPattern: v))"
            case "fixed64": return "\(pad)\(name): \(v)"
            case "sfixed64": return "\(pad)\(name): \(Int64(bitPattern: v))"
            default: return raw()
            }
        case .bytes(let d):
            if type == "string" {
                if let s = String(data: d, encoding: .utf8) { return "\(pad)\(name): \"\(Self.escape(s))\"" }
                return raw()
            }
            if type == "bytes" {
                return "\(pad)\(name): <\(d.count) bytes> " + d.prefix(32).map { String(format: "%02x", $0) }.joined() + (d.count > 32 ? "…" : "")
            }
            if let full = resolve(type, from: scope), messages[full] != nil, depth < 16 {
                if d.isEmpty { return "\(pad)\(name) {\n\(pad)}" }
                if let nested = ProtobufDecoder.decode(d) {
                    return "\(pad)\(name) {\n" + render(nested, type: full, indent: indent + 1, depth: depth + 1) + "\n\(pad)}"
                }
            }
            return raw()
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - Tokenizer and parser

private enum Tok: Equatable {
    case ident(String), number(String), string(String), sym(Character)
}

private enum Tokenizer {
    static func tokens(_ s: String) -> [Tok] {
        let c = Array(s.unicodeScalars)
        var i = 0
        var out: [Tok] = []
        func isIdent(_ u: Unicode.Scalar) -> Bool { u == "_" || u == "." || (u.properties.isAlphabetic && u.isASCII) || ("0"..."9").contains(u) }
        while i < c.count {
            let u = c[i]
            if u.properties.isWhitespace { i += 1; continue }
            if u == "/", i + 1 < c.count, c[i + 1] == "/" { while i < c.count, c[i] != "\n" { i += 1 }; continue }
            if u == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i += 2; continue
            }
            if u == "\"" || u == "'" {
                var str = ""; i += 1
                while i < c.count, c[i] != u { if c[i] == "\\", i + 1 < c.count { i += 1 }; str.unicodeScalars.append(c[i]); i += 1 }
                i += 1; out.append(.string(str)); continue
            }
            if ("0"..."9").contains(u) || (u == "-" && i + 1 < c.count && ("0"..."9").contains(c[i + 1])) {
                var n = String(u); i += 1
                while i < c.count, isIdent(c[i]) || c[i] == "+" || c[i] == "-" { n.unicodeScalars.append(c[i]); i += 1 }
                out.append(.number(n)); continue
            }
            if isIdent(u) {
                var n = ""
                while i < c.count, isIdent(c[i]) { n.unicodeScalars.append(c[i]); i += 1 }
                out.append(.ident(n)); continue
            }
            out.append(.sym(Character(u))); i += 1
        }
        return out
    }
}

private struct Parser {
    var tokens: [Tok]
    var i = 0
    var package = ""
    var messages: [ProtoSchema.Message] = []
    var enums: [ProtoSchema.Enum] = []
    var methods: [String: ProtoSchema.Method] = [:]
    private var rawMethods: [(path: String, input: String, output: String, scope: String)] = []

    init(tokens: [Tok]) { self.tokens = tokens }

    var peek: Tok? { i < tokens.count ? tokens[i] : nil }
    mutating func next() -> Tok? { defer { i += 1 }; return peek }
    mutating func eat(_ c: Character) -> Bool { if peek == .sym(c) { i += 1; return true }; return false }
    mutating func ident() -> String? { if case .ident(let s)? = peek { i += 1; return s }; return nil }

    mutating func skipStatement() {
        var depth = 0
        while let t = next() {
            if t == .sym("{") { depth += 1 }
            if t == .sym("}") { depth -= 1; if depth <= 0 { if depth == 0 { _ = eat(";") }; return } }
            if t == .sym(";"), depth == 0 { return }
        }
    }

    mutating func parseFile() -> Bool {
        while let t = peek {
            guard case .ident(let kw) = t else { i += 1; continue }
            i += 1
            switch kw {
            case "package":
                package = ident() ?? ""; _ = eat(";")
            case "message":
                guard parseMessage(scope: package) else { return false }
            case "enum":
                guard parseEnum(scope: package) else { return false }
            case "service":
                guard parseService() else { return false }
            default:
                i -= 1; skipStatement()
            }
        }
        for m in rawMethods {
            let a = qualify(m.input, scope: m.scope), b = qualify(m.output, scope: m.scope)
            methods[m.path] = ProtoSchema.Method(input: a, output: b)
        }
        return true
    }

    /// Method types are resolved lazily against the package; messages from other files resolve at lookup time.
    func qualify(_ name: String, scope: String) -> String {
        if name.hasPrefix(".") { return String(name.dropFirst()) }
        if scope.isEmpty || name.contains(".") && messages.contains(where: { $0.fullName == name }) { return name }
        let inPackage = scope + "." + name
        if messages.contains(where: { $0.fullName == inPackage }) { return inPackage }
        return name.contains(".") ? name : inPackage
    }

    mutating func parseService() -> Bool {
        guard let name = ident(), eat("{") else { return false }
        while let t = peek, t != .sym("}") {
            if case .ident("rpc") = t {
                i += 1
                guard let method = ident(), eat("(") else { return false }
                if case .ident("stream")? = peek { i += 1 }
                guard let input = ident(), eat(")") else { return false }
                guard case .ident("returns")? = next(), eat("(") else { return false }
                if case .ident("stream")? = peek { i += 1 }
                guard let output = ident(), eat(")") else { return false }
                rawMethods.append((path: "/" + (package.isEmpty ? "" : package + ".") + name + "/" + method, input: input, output: output, scope: package))
                if peek == .sym("{") { skipStatement() } else { _ = eat(";") }
            } else {
                skipStatement()
            }
        }
        return eat("}")
    }

    mutating func parseEnum(scope: String) -> Bool {
        guard let name = ident(), eat("{") else { return false }
        var e = ProtoSchema.Enum(fullName: scope.isEmpty ? name : scope + "." + name)
        while let t = peek, t != .sym("}") {
            if case .ident(let n) = t, tokens.indices.contains(i + 2), tokens[i + 1] == .sym("="), case .number(let num) = tokens[i + 2], n != "option", n != "reserved" {
                let value = Int(num) ?? (num.hasPrefix("0x") ? Int(num.dropFirst(2), radix: 16) : nil)
                if let value, e.values[value] == nil { e.values[value] = n }
                skipStatement()
            } else {
                skipStatement()
            }
        }
        enums.append(e)
        return eat("}")
    }

    mutating func parseMessage(scope: String) -> Bool {
        guard let name = ident(), eat("{") else { return false }
        let full = scope.isEmpty ? name : scope + "." + name
        var m = ProtoSchema.Message(fullName: full)
        guard parseBody(&m, full: full) else { return false }
        messages.append(m)
        return true
    }

    mutating func parseBody(_ m: inout ProtoSchema.Message, full: String) -> Bool {
        while let t = peek, t != .sym("}") {
            guard case .ident(let kw) = t else { i += 1; continue }
            switch kw {
            case "message": i += 1; guard parseMessage(scope: full) else { return false }
            case "enum": i += 1; guard parseEnum(scope: full) else { return false }
            case "oneof":
                i += 1; _ = ident()
                guard eat("{") else { return false }
                guard parseBody(&m, full: full) else { return false }
            case "option", "reserved", "extensions", "extend", "syntax", "import": skipStatement()
            default:
                guard parseField(&m) else { return false }
            }
        }
        return eat("}")
    }

    mutating func parseField(_ m: inout ProtoSchema.Message) -> Bool {
        var repeated = false
        if case .ident(let q)? = peek, q == "repeated" || q == "optional" || q == "required" { repeated = q == "repeated"; i += 1 }
        guard var type = ident() else { skipStatement(); return true }
        var mapKey: String?
        if type == "map" {
            guard eat("<"), let k = ident(), eat(","), let v = ident(), eat(">") else { return false }
            mapKey = k; type = v; repeated = true
        }
        guard let name = ident(), eat("="), case .number(let n)? = next(), let number = Int(n) else { skipStatement(); return true }
        if type == "group" { skipStatement(); return true }
        m.fields[number] = ProtoSchema.Field(name: name, number: number, type: type, repeated: repeated, mapKey: mapKey)
        skipStatement()
        return true
    }
}
