import Foundation

/// Copy-as-cURL for a captured request.
public enum CURLExporter {
    public static func command(for request: HTTPRequestRecord) -> String {
        var parts = ["curl", "-X", request.method, quote(request.url.absoluteString)]
        for h in request.headers where !["content-length", "host", "connection"].contains(h.name.lowercased()) {
            parts += ["-H", quote("\(h.name): \(h.value)")]
        }
        if !request.body.isEmpty {
            if let text = String(data: request.body, encoding: .utf8) {
                parts += ["--data-raw", quote(text)]
            } else {
                parts += ["--data-binary", quote("<\(request.body.count) bytes of binary data>")]
            }
        }
        return parts.joined(separator: " ")
    }

    /// POSIX single-quote escaping.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Display helpers for request/response bodies.
public enum BodyFormatter {
    /// Pretty-printed JSON, or nil if `data` is not JSON.
    public static func prettyJSON(_ data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return nil }
        return String(data: out, encoding: .utf8)
    }

    /// `offset  hex bytes  |ascii|`, 16 bytes per line.
    public static func hexDump(_ data: Data, limit: Int = 64 * 1024) -> String {
        let bytes = [UInt8](data.prefix(limit))
        var lines: [String] = []
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[start..<min(start + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { (0x20..<0x7f).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", start) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  |" + ascii + "|")
        }
        if data.count > limit { lines.append("… \(data.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }

    public static func byteCount(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
