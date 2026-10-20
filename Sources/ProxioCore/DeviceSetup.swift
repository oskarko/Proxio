import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Addresses of this Mac that other devices on the network can reach.
public enum LocalNetwork {
    public struct Address: Equatable, Sendable, Identifiable {
        public let interface: String
        public let ip: String
        public var id: String { interface + ip }
    }

    /// IPv4 addresses of active, non-loopback interfaces, Wi-Fi/Ethernet (`en*`) first.
    public static func ipv4Addresses() -> [Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Address] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil else { continue }
            let ip = String(cString: buf)
            guard !ip.hasPrefix("169.254.") else { continue }
            out.append(Address(interface: String(cString: p.pointee.ifa_name), ip: ip))
        }
        return out.sorted { ($0.interface.hasPrefix("en") ? 0 : 1, $0.interface) < ($1.interface.hasPrefix("en") ? 0 : 1, $1.interface) }
    }

    /// Private (RFC 1918), link-local, loopback and carrier-grade NAT ranges: the only peers a LAN-facing proxy should serve.
    public static func isPrivate(ipv4 ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }
}

/// Apple configuration profile carrying a root certificate, installable from Safari on iOS.
public enum MobileConfig {
    public static func profile(certificateDER: Data, name: String = "Proxio Root CA", identifier: String = "dev.proxio.rootca") -> Data {
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>PayloadContent</key>
          <array>
            <dict>
              <key>PayloadCertificateFileName</key><string>proxio-ca.cer</string>
              <key>PayloadContent</key><data>\(certificateDER.base64EncodedString())</data>
              <key>PayloadDescription</key><string>Adds the Proxio root certificate</string>
              <key>PayloadDisplayName</key><string>\(escape(name))</string>
              <key>PayloadIdentifier</key><string>\(identifier).cert</string>
              <key>PayloadType</key><string>com.apple.security.root</string>
              <key>PayloadUUID</key><string>\(uuid(from: certificateDER, salt: 1))</string>
              <key>PayloadVersion</key><integer>1</integer>
            </dict>
          </array>
          <key>PayloadDescription</key><string>Lets this device trust traffic decrypted by Proxio. Remove it when you are done.</string>
          <key>PayloadDisplayName</key><string>\(escape(name))</string>
          <key>PayloadIdentifier</key><string>\(identifier)</string>
          <key>PayloadOrganization</key><string>Proxio</string>
          <key>PayloadRemovalDisallowed</key><false/>
          <key>PayloadType</key><string>Configuration</string>
          <key>PayloadUUID</key><string>\(uuid(from: certificateDER, salt: 2))</string>
          <key>PayloadVersion</key><integer>1</integer>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    /// Stable UUID derived from the certificate, so reinstalling the same CA replaces the profile instead of stacking copies.
    private static func uuid(from data: Data, salt: UInt8) -> String {
        var bytes = [UInt8](repeating: salt, count: 16)
        for (i, b) in data.enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}
