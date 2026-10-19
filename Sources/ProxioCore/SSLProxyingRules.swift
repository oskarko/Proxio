import Foundation

/// `host`, `*.host` (subdomains only, not the apex) or `*`, with an optional `:port`.
public struct HostPattern: Sendable, Hashable, Codable, CustomStringConvertible {
    public let host: String
    public let port: Int?

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        var port: Int?
        if text.filter({ $0 == ":" }).count == 1, let idx = text.lastIndex(of: ":") {
            guard let p = Int(text[text.index(after: idx)...]), (1...65535).contains(p) else { return nil }
            port = p
            text = String(text[..<idx])
        }
        guard !text.isEmpty, !text.contains("/"), !text.contains(" ") else { return nil }
        if text.contains("*"), text != "*", !(text.hasPrefix("*.") && !text.dropFirst(2).contains("*")) { return nil }
        self.host = text
        self.port = port
    }

    public var description: String { port.map { "\(host):\($0)" } ?? host }

    public func matches(host candidate: String, port candidatePort: Int) -> Bool {
        if let port, port != candidatePort { return false }
        let h = candidate.lowercased()
        if host == "*" { return true }
        if host.hasPrefix("*.") { return h.hasSuffix(String(host.dropFirst(1))) && h.count > host.count - 1 }
        return h == host
    }
}

/// Which CONNECT targets get TLS-intercepted. Exclusions win over inclusions.
public struct SSLProxyingRules: Sendable, Equatable, Codable {
    public var include: [HostPattern]
    public var exclude: [HostPattern]
    public var interceptByDefault: Bool

    public init(include: [HostPattern] = [], exclude: [HostPattern] = [], interceptByDefault: Bool) {
        self.include = include
        self.exclude = exclude
        self.interceptByDefault = interceptByDefault
    }

    public static let interceptAll = SSLProxyingRules(interceptByDefault: true)
    public static let interceptNothing = SSLProxyingRules(interceptByDefault: false)

    public func shouldIntercept(host: String, port: Int) -> Bool {
        if exclude.contains(where: { $0.matches(host: host, port: port) }) { return false }
        if include.contains(where: { $0.matches(host: host, port: port) }) { return true }
        return interceptByDefault
    }
}

/// Live, thread-safe holder so rules can change while the proxy is running.
public final class SSLProxyingPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SSLProxyingRules

    public init(_ rules: SSLProxyingRules = .interceptAll) { current = rules }

    public var rules: SSLProxyingRules {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); defer { lock.unlock() }; current = newValue }
    }
}
