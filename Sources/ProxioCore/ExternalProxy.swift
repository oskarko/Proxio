import Foundation

/// An upstream HTTP proxy that Proxio forwards traffic through (corporate proxy, another debugger, ...).
public struct ExternalProxy: Sendable, Equatable, Codable {
    public var isEnabled: Bool
    public var host: String
    public var port: Int
    public var username: String
    /// Kept out of the rules file; the app stores it in the Keychain.
    public var password: String
    /// Comma-separated host globs that go direct. Loopback always does.
    public var bypass: String

    private enum CodingKeys: String, CodingKey { case isEnabled, host, port, username, bypass }

    public init(isEnabled: Bool = false, host: String = "", port: Int = 8080, username: String = "", password: String = "", bypass: String = "localhost, 127.0.0.1, *.local") {
        self.isEnabled = isEnabled
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.bypass = bypass
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = ExternalProxy(isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
                             host: try c.decodeIfPresent(String.self, forKey: .host) ?? "",
                             port: try c.decodeIfPresent(Int.self, forKey: .port) ?? 8080,
                             username: try c.decodeIfPresent(String.self, forKey: .username) ?? "",
                             bypass: try c.decodeIfPresent(String.self, forKey: .bypass) ?? "")
    }

    public var isUsable: Bool { isEnabled && !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port) }

    /// Whether traffic to `target` should go through this proxy.
    public func applies(to target: String) -> Bool {
        guard isUsable else { return false }
        let lower = target.lowercased()
        if lower == "localhost" || lower == "::1" || lower.hasPrefix("127.") { return false }
        let globs = bypass.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return !globs.contains { HostGlob.matches($0, host: lower, port: nil) }
    }

    /// `Proxy-Authorization` value, or nil without credentials.
    public var authorization: String? {
        guard !username.isEmpty else { return nil }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}
