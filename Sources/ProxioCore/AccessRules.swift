import Foundation

/// A URL pattern that is either blocked or, on the allow list, the only thing let through.
public struct AccessRule: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    public var matcher: RequestMatcher

    public init(id: UUID = UUID(), isEnabled: Bool = true, matcher: RequestMatcher) {
        self.id = id
        self.isEnabled = isEnabled
        self.matcher = matcher
    }
}

/// Connects to `address` instead of resolving `host` (TLS name and Host header stay the original).
public struct DNSRule: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    /// Host glob, e.g. `api.example.com` or `*.example.com`.
    public var hostPattern: String
    /// An IP address or another host name.
    public var address: String

    public init(id: UUID = UUID(), isEnabled: Bool = true, hostPattern: String, address: String) {
        self.id = id
        self.isEnabled = isEnabled
        self.hostPattern = hostPattern
        self.address = address
    }
}

/// Hosts Proxio relays untouched and does not record.
public struct BypassRule: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    public var hostPattern: String

    public init(id: UUID = UUID(), isEnabled: Bool = true, hostPattern: String) {
        self.id = id
        self.isEnabled = isEnabled
        self.hostPattern = hostPattern
    }
}

enum HostGlob {
    /// `pattern` is compared with `host` and with `host:port`.
    static func matches(_ pattern: String, host: String, port: Int?) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return false }
        if Glob.matches(pattern: p, text: host) { return true }
        if let port, Glob.matches(pattern: p, text: "\(host):\(port)") { return true }
        return false
    }
}

public extension RequestMatcher {
    /// Whether the host part of the pattern (before the first `/`) covers `host`; used where only the host is known (CONNECT).
    /// True when the pattern names a whole host, with no path to narrow it down.
    var isHostWide: Bool {
        var p = urlPattern.trimmingCharacters(in: .whitespaces)
        if let r = p.range(of: "://") { p = String(p[r.upperBound...]) }
        return method?.isEmpty != false && (!p.contains("/") || p.hasSuffix("/*") && !p.dropLast(2).contains("/"))
    }

    func coversHost(_ host: String, port: Int?) -> Bool {
        var p = urlPattern.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return true }
        if let r = p.range(of: "://") { p = String(p[r.upperBound...]) }
        let hostPart = p.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? p
        return HostGlob.matches(hostPart, host: host, port: port)
    }
}
