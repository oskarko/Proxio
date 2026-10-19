import Foundation
import Compression

/// Decodes `Content-Encoding` (gzip, deflate, br) for display. Captured bodies stay as received.
public enum ContentDecoder {
    /// Decoded output is capped so a hostile "zip bomb" cannot exhaust memory.
    static let limit = 64 * 1024 * 1024

    /// Returns nil for unknown encodings or corrupt data. Encodings applied in order are undone in reverse.
    public static func decode(_ data: Data, encoding: String) -> Data? {
        var result = data
        let steps = encoding.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { $0 != "identity" && !$0.isEmpty }
        for step in steps.reversed() {
            switch step {
            case "gzip", "x-gzip": guard let d = gunzip(result) else { return nil }; result = d
            case "deflate": guard let d = inflate(result) else { return nil }; result = d
            case "br": guard let d = run(result, algorithm: COMPRESSION_BROTLI) else { return nil }; result = d
            default: return nil
            }
        }
        return result
    }

    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data.prefix(10))
        guard b.count == 10, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        let bytes = [UInt8](data)
        if flags & 4 != 0 {                       // FEXTRA
            guard i + 2 <= bytes.count else { return nil }
            i += 2 + Int(bytes[i]) + (Int(bytes[i + 1]) << 8)
        }
        for bit: UInt8 in [8, 16] where flags & bit != 0 {   // FNAME, FCOMMENT: zero-terminated
            guard let end = bytes[min(i, bytes.count)...].firstIndex(of: 0) else { return nil }
            i = end + 1
        }
        if flags & 2 != 0 { i += 2 }              // FHCRC
        guard i < bytes.count - 8 else { return nil }
        return run(Data(bytes[i..<(bytes.count - 8)]), algorithm: COMPRESSION_ZLIB)   // drop CRC32 + size trailer
    }

    /// HTTP "deflate" is normally zlib-wrapped, but some servers send raw deflate.
    static func inflate(_ data: Data) -> Data? {
        if data.count > 2, data[data.startIndex] & 0x0f == 8, ((Int(data[data.startIndex]) << 8) + Int(data[data.startIndex + 1])) % 31 == 0,
           let d = run(data.dropFirst(2), algorithm: COMPRESSION_ZLIB) { return d }
        return run(data, algorithm: COMPRESSION_ZLIB)
    }

    private static func run(_ input: Data, algorithm: compression_algorithm) -> Data? {
        guard !input.isEmpty else { return Data() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }

        let chunk = 64 * 1024
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }
        var result = Data()
        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = out
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                result.append(out, count: chunk - stream.pointee.dst_size)
                if result.count > limit { return nil }
                switch status {
                case COMPRESSION_STATUS_END: return result
                case COMPRESSION_STATUS_OK: continue
                default: return nil
                }
            }
        }
    }
}

public extension HTTPRequestRecord {
    /// Body with `Content-Encoding` undone, or the raw body if it cannot be decoded.
    var decodedBody: Data { ContentDecoder.decodeBody(body, headers: headers) }
}

public extension HTTPResponseRecord {
    var decodedBody: Data { ContentDecoder.decodeBody(body, headers: headers) }
}

extension ContentDecoder {
    static func decodeBody(_ body: Data, headers: [HTTPHeader]) -> Data {
        guard !body.isEmpty,
              let encoding = headers.first(where: { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame })?.value
        else { return body }
        return decode(body, encoding: encoding) ?? body
    }
}
