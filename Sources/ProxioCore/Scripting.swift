import Foundation
import JavaScriptCore

/// A user script that can rewrite matching requests and responses. The source may define
/// `onRequest(request)` and/or `onResponse(request, response)`; each returns the (possibly modified)
/// object, or nothing to keep the argument as mutated.
public struct ProxioScript: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var matcher: RequestMatcher
    public var source: String

    public init(id: UUID = UUID(), name: String = "Script", isEnabled: Bool = true,
                matcher: RequestMatcher = RequestMatcher(urlPattern: ""), source: String = ProxioScript.template) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.matcher = matcher
        self.source = source
    }

    public static let template = """
    // request: { method, url, headers: {Name: value}, body: string | null }
    function onRequest(request) {
      // request.headers["X-Debug"] = "1";
      return request;
    }

    // response: { status, headers: {Name: value}, body: string | null } (body is already decompressed)
    function onResponse(request, response) {
      // console.log(request.url, response.status);
      return response;
    }
    """
}

/// Runs scripts with JavaScriptCore. No network, file or process access is exposed to scripts,
/// only `console.log`. A script that never returns blocks the request it runs on (JavaScriptCore has
/// no public way to interrupt it), so keep scripts short.
public final class ScriptEngine: @unchecked Sendable {
    public struct Outcome<Value> {
        public var value: Value
        /// One line per script that changed the message, or failed.
        public var notes: [String]
    }

    private let lock = NSLock()
    private var contexts: [UUID: (source: String, context: JSContext?, error: String?)] = [:]
    /// Called with (script name, text) for every `console.log`.
    public var onLog: (@Sendable (String, String) -> Void)?

    public init() {}

    public func transform(_ request: HTTPRequestRecord, with scripts: [ProxioScript]) -> Outcome<HTTPRequestRecord> {
        var current = request
        var notes: [String] = []
        for script in scripts {
            guard script.isEnabled, script.matcher.matches(method: current.method, url: current.url) else { continue }
            switch call("onRequest", script: script, request: current, response: nil) {
            case .skipped: continue
            case .failed(let message): notes.append("Script \(script.name) failed: \(message)")
            case .result(let object):
                let updated = Self.applying(object, toRequest: current)
                if updated != current { notes.append("Script: \(script.name)") }
                current = updated
            }
        }
        return Outcome(value: current, notes: notes)
    }

    public func transform(_ response: HTTPResponseRecord, for request: HTTPRequestRecord, with scripts: [ProxioScript]) -> Outcome<HTTPResponseRecord> {
        var current = response
        var notes: [String] = []
        for script in scripts {
            guard script.isEnabled, script.matcher.matches(method: request.method, url: request.url) else { continue }
            switch call("onResponse", script: script, request: request, response: current) {
            case .skipped: continue
            case .failed(let message): notes.append("Script \(script.name) failed: \(message)")
            case .result(let object):
                let updated = Self.applying(object, toResponse: current)
                if updated != current { notes.append("Script: \(script.name)") }
                current = updated
            }
        }
        return Outcome(value: current, notes: notes)
    }

    // MARK: JavaScript bridge

    private enum CallResult { case skipped, failed(String), result([String: Any]) }

    private static let bridge = """
    function __proxioCall(name, a, b) {
      var f = globalThis[name];
      if (typeof f !== 'function') return null;
      var req = JSON.parse(a);
      var res = b === null ? undefined : JSON.parse(b);
      var out = res === undefined ? f(req) : f(req, res);
      if (out === undefined) out = res === undefined ? req : res;
      return JSON.stringify(out);
    }
    """

    private func call(_ function: String, script: ProxioScript, request: HTTPRequestRecord, response: HTTPResponseRecord?) -> CallResult {
        lock.lock(); defer { lock.unlock() }
        let entry = context(for: script)
        if let error = entry.error { return .failed(error) }
        guard let context = entry.context else { return .skipped }
        guard context.objectForKeyedSubscript(function)?.isObject == true else { return .skipped }

        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() ?? "unknown error" }
        let requestJSON = Self.json(Self.object(for: request))
        let responseJSON = response.map { Self.json(Self.object(for: $0)) }
        let value = context.objectForKeyedSubscript("__proxioCall")?
            .call(withArguments: [function, requestJSON, responseJSON ?? NSNull()])
        if let failure { return .failed(failure) }
        guard let text = value?.toString(), value?.isString == true,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        else { return .failed("\(function) must return an object") }
        return .result(object)
    }

    private func context(for script: ProxioScript) -> (context: JSContext?, error: String?) {
        if let cached = contexts[script.id], cached.source == script.source { return (cached.context, cached.error) }
        guard let context = JSContext() else { return (nil, "JavaScript is unavailable") }
        var error: String?
        context.exceptionHandler = { _, exception in error = exception?.toString() ?? "unknown error" }
        let name = script.name
        let log: @convention(block) () -> Void = { [weak self] in
            let text = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }.joined(separator: " ")
            self?.onLog?(name, text)
        }
        let console = JSValue(newObjectIn: context)
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        console?.setObject(log, forKeyedSubscript: "warn" as NSString)
        console?.setObject(log, forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        context.evaluateScript(Self.bridge)
        context.evaluateScript(script.source)
        let entry = (source: script.source, context: Optional(context), error: error)
        contexts[script.id] = entry
        return (entry.context, entry.error)
    }

    // MARK: Conversion

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func headerObject(_ headers: [HTTPHeader]) -> [String: String] {
        var out: [String: String] = [:]
        for h in headers { out[h.name] = out[h.name].map { $0 + ", " + h.value } ?? h.value }
        return out
    }

    private static func object(for r: HTTPRequestRecord) -> [String: Any] {
        ["method": r.method, "url": r.url.absoluteString, "headers": headerObject(r.headers),
         "body": String(data: r.body, encoding: .utf8) ?? NSNull()]
    }

    private static func object(for r: HTTPResponseRecord) -> [String: Any] {
        let body = r.decodedBody
        return ["status": r.status, "headers": headerObject(r.headers), "body": String(data: body, encoding: .utf8) ?? NSNull()]
    }

    /// Entries whose value the script left alone keep their original (possibly repeated) header lines.
    private static func headers(from value: Any?, original: [HTTPHeader]) -> [HTTPHeader] {
        guard let dict = value as? [String: Any] else { return original }
        let before = headerObject(original)
        var out: [HTTPHeader] = []
        var kept = Set<String>()
        for h in original {
            guard let now = dict[h.name] as? String, now == before[h.name] else { continue }
            out.append(h); kept.insert(h.name)
        }
        for (name, v) in dict.sorted(by: { $0.key < $1.key }) where !kept.contains(name) {
            let text = (v as? String) ?? "\(v)"
            if !original.contains(where: { $0.name == name }) || text != before[name] { out.append(HTTPHeader(name: name, value: text)) }
        }
        return out
    }

    private static func applying(_ o: [String: Any], toRequest r: HTTPRequestRecord) -> HTTPRequestRecord {
        var out = r
        if let m = o["method"] as? String, !m.isEmpty { out.method = m.uppercased() }
        if let u = (o["url"] as? String).flatMap(URL.init(string:)), u.host != nil { out.url = u }
        out.headers = headers(from: o["headers"], original: r.headers)
        applyBody(o["body"], into: &out.body, headers: &out.headers, original: r.body)
        return out
    }

    private static func applying(_ o: [String: Any], toResponse r: HTTPResponseRecord) -> HTTPResponseRecord {
        var out = r
        if let s = o["status"] as? Int, (100...599).contains(s), s != r.status {
            out.status = s
            out.reason = HTTPURLResponse.localizedString(forStatusCode: s).capitalized
        }
        out.headers = headers(from: o["headers"], original: r.headers)
        // The script saw the decompressed body; only replace the stored one when it changed.
        let decodedText = String(data: r.decodedBody, encoding: .utf8)
        if let text = o["body"] as? String, text != decodedText {
            out.body = Data(text.utf8)
            out.headers.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
        } else if o["body"] is NSNull, decodedText != nil {
            out.body = Data()
            out.headers.removeAll { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame }
        }
        return out
    }

    private static func applyBody(_ value: Any?, into body: inout Data, headers: inout [HTTPHeader], original: Data) {
        if let text = value as? String {
            if text != String(data: original, encoding: .utf8) { body = Data(text.utf8) }
        } else if value is NSNull, String(data: original, encoding: .utf8) != nil {
            body = Data()
        }
    }
}
