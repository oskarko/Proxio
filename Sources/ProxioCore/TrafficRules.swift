import Foundation

/// Selects requests by method and a URL glob. `*` matches any run of characters.
/// A pattern without a scheme is compared with `host[:port]/path?query`; one without
/// a `/` matches the whole host (`example.com` == `example.com/*`).
public struct RequestMatcher: Sendable, Hashable, Codable {
    public var method: String?
    public var urlPattern: String

    public init(method: String? = nil, urlPattern: String) {
        self.method = method
        self.urlPattern = urlPattern
    }

    public func matches(method requestMethod: String, url: URL) -> Bool {
        if let method, !method.isEmpty, method.caseInsensitiveCompare(requestMethod) != .orderedSame { return false }
        var pattern = urlPattern.trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty { return true }
        let target: String
        if pattern.contains("://") {
            target = url.absoluteString
        } else {
            var t = url.host ?? ""
            if let port = url.port { t += ":\(port)" }
            t += url.path.isEmpty ? "/" : url.path
            if let q = url.query { t += "?\(q)" }
            target = t
            if !pattern.contains("/") { pattern += "/*" }
        }
        return Glob.matches(pattern: pattern, text: target)
    }
}

enum Glob {
    /// Case-insensitive wildcard match with `*` only.
    static func matches(pattern: String, text: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if pi < p.count, p[pi] == t[ti] { pi += 1; ti += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

/// Pauses matching traffic so it can be inspected and edited before it moves on.
public struct Breakpoint: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    public var matcher: RequestMatcher
    public var onRequest: Bool
    public var onResponse: Bool

    public init(id: UUID = UUID(), isEnabled: Bool = true, matcher: RequestMatcher, onRequest: Bool = true, onResponse: Bool = true) {
        self.id = id
        self.isEnabled = isEnabled
        self.matcher = matcher
        self.onRequest = onRequest
        self.onResponse = onResponse
    }
}

/// Receives paused messages. Return the (possibly edited) message to let it continue, or nil to cancel it.
public protocol BreakpointHandler: Sendable {
    func resume(request: HTTPRequestRecord) async -> HTTPRequestRecord?
    func resume(response: HTTPResponseRecord, for request: HTTPRequestRecord) async -> HTTPResponseRecord?
}

/// Live, thread-safe rule set shared with the running proxy; can be edited while it serves traffic.
public final class TrafficRules: @unchecked Sendable {
    private let lock = NSLock()
    private var _breakpoints: [Breakpoint] = []
    private var _handler: BreakpointHandler?

    public init() {}

    public var breakpoints: [Breakpoint] {
        get { lock.withLock { _breakpoints } }
        set { lock.withLock { _breakpoints = newValue } }
    }

    public var breakpointHandler: BreakpointHandler? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    /// The handler to ask, when an enabled breakpoint covers this message.
    public func breakpointHandler(request: HTTPRequestRecord, phase: Phase) -> BreakpointHandler? {
        lock.withLock {
            guard let handler = _handler else { return nil }
            let hit = _breakpoints.contains {
                $0.isEnabled && (phase == .request ? $0.onRequest : $0.onResponse)
                    && $0.matcher.matches(method: request.method, url: request.url)
            }
            return hit ? handler : nil
        }
    }

    public enum Phase: Sendable { case request, response }
}
