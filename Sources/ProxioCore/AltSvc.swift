import Foundation

/// Proxio cannot decrypt QUIC, so it stops origins from advertising HTTP/3 (`Alt-Svc: h3=":443"`).
/// Clients that never learn about h3 keep using the TCP connection that goes through the proxy.
public enum AltSvc {
    public static func removingHTTP3(from headers: [HTTPHeader]) -> [HTTPHeader] {
        headers.compactMap { header in
            guard header.name.caseInsensitiveCompare("Alt-Svc") == .orderedSame else { return header }
            let kept = header.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { entry in
                let proto = entry.split(separator: "=", maxSplits: 1).first.map { $0.lowercased() } ?? ""
                return !(proto == "h3" || proto.hasPrefix("h3-") || proto.hasPrefix("quic"))
            }
            return kept.isEmpty ? nil : HTTPHeader(name: header.name, value: kept.joined(separator: ", "))
        }
    }
}
