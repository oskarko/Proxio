import Foundation
import UniformTypeIdentifiers

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

/// Answers matching requests from a file or inline body without contacting the server.
public struct MapLocalRule: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    public var matcher: RequestMatcher
    public var status: Int
    public var headers: [HTTPHeader]
    /// Used when `filePath` is nil.
    public var body: Data
    /// Read on every match, so edits to the file take effect immediately.
    public var filePath: String?

    public init(id: UUID = UUID(), isEnabled: Bool = true, matcher: RequestMatcher, status: Int = 200,
                headers: [HTTPHeader] = [], body: Data = Data(), filePath: String? = nil) {
        self.id = id
        self.isEnabled = isEnabled
        self.matcher = matcher
        self.status = status
        self.headers = headers
        self.body = body
        self.filePath = filePath
    }

    public func makeResponse() -> HTTPResponseRecord {
        var payload = body
        var contentType: String?
        if let filePath, !filePath.isEmpty {
            let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else {
                return HTTPResponseRecord(
                    status: 500, reason: "Map Local file unreadable",
                    headers: [HTTPHeader(name: "Content-Type", value: "text/plain")],
                    body: Data("Proxio could not read \(url.path)".utf8)
                )
            }
            payload = data
            contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        } else if (try? JSONSerialization.jsonObject(with: payload)) != nil {
            contentType = "application/json"
        }
        var out = headers.filter { !["content-length", "transfer-encoding", "connection"].contains($0.name.lowercased()) }
        if !out.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            out.append(HTTPHeader(name: "Content-Type", value: contentType ?? "text/plain"))
        }
        return HTTPResponseRecord(
            status: status,
            reason: HTTPURLResponse.localizedString(forStatusCode: status).capitalized,
            headers: out, body: payload
        )
    }
}

/// Redirects matching requests to another origin. Empty fields keep the original value.
public struct MapRemoteRule: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    public var matcher: RequestMatcher
    public var scheme: String?
    public var host: String?
    public var port: Int?
    /// Replaces the whole path (the query string is kept).
    public var path: String?

    public init(id: UUID = UUID(), isEnabled: Bool = true, matcher: RequestMatcher,
                scheme: String? = nil, host: String? = nil, port: Int? = nil, path: String? = nil) {
        self.id = id
        self.isEnabled = isEnabled
        self.matcher = matcher
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }

    public func rewritten(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let scheme, !scheme.isEmpty { c.scheme = scheme.lowercased() }
        if let host, !host.isEmpty { c.host = host }
        if let port { c.port = port }
        if let path, !path.isEmpty { c.percentEncodedPath = path.hasPrefix("/") ? path : "/" + path }
        return c.url
    }

    public var summary: String {
        let target = [scheme.flatMap { $0.isEmpty ? nil : "\($0)://" }, host, port.map { ":\($0)" }, path].compactMap { $0 }.joined()
        return "Map Remote → \(target)"
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
    private var _mapLocal: [MapLocalRule] = []
    private var _mapRemote: [MapRemoteRule] = []

    public init() {}

    public var mapLocalRules: [MapLocalRule] {
        get { lock.withLock { _mapLocal } }
        set { lock.withLock { _mapLocal = newValue } }
    }

    public var mapRemoteRules: [MapRemoteRule] {
        get { lock.withLock { _mapRemote } }
        set { lock.withLock { _mapRemote = newValue } }
    }

    /// First enabled Map Local rule that matches.
    public func mapLocal(for request: HTTPRequestRecord) -> MapLocalRule? {
        lock.withLock { _mapLocal.first { $0.isEnabled && $0.matcher.matches(method: request.method, url: request.url) } }
    }

    /// First enabled Map Remote rule that matches and actually changes the URL.
    public func mapRemote(for request: HTTPRequestRecord) -> (rule: MapRemoteRule, url: URL)? {
        lock.withLock {
            for rule in _mapRemote where rule.isEnabled && rule.matcher.matches(method: request.method, url: request.url) {
                if let url = rule.rewritten(request.url), url != request.url { return (rule, url) }
            }
            return nil
        }
    }

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
