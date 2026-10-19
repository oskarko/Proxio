import Testing
import Foundation
@testable import ProxioCore

@Suite struct ScriptingTests {
    let request = HTTPRequestRecord(
        method: "GET", url: URL(string: "https://api.example.com/v1/users?x=1")!,
        headers: [HTTPHeader(name: "Accept", value: "*/*"), HTTPHeader(name: "X-Old", value: "1")]
    )
    let response = HTTPResponseRecord(
        status: 200, reason: "OK",
        headers: [HTTPHeader(name: "Content-Type", value: "application/json"), HTTPHeader(name: "Set-Cookie", value: "a=1"), HTTPHeader(name: "Set-Cookie", value: "b=2")],
        body: Data(#"{"name":"ana"}"#.utf8)
    )

    @Test func requestScriptEditsMethodUrlAndHeaders() {
        let script = ProxioScript(name: "edit", source: """
        function onRequest(r) { r.headers["X-Debug"] = "1"; delete r.headers["X-Old"]; r.url = r.url.replace("/v1/", "/v2/"); return r; }
        """)
        let out = ScriptEngine().transform(request, with: [script])
        #expect(out.value.url.absoluteString == "https://api.example.com/v2/users?x=1")
        #expect(out.value.headers.contains(HTTPHeader(name: "X-Debug", value: "1")))
        #expect(!out.value.headers.contains { $0.name == "X-Old" })
        #expect(out.value.headers.contains(HTTPHeader(name: "Accept", value: "*/*")))
        #expect(out.notes == ["Script: edit"])
    }

    @Test func responseScriptEditsBodyAndKeepsRepeatedHeaders() throws {
        let script = ProxioScript(name: "body", source: """
        function onResponse(req, res) { var o = JSON.parse(res.body); o.name = o.name.toUpperCase(); res.body = JSON.stringify(o); res.status = 201; }
        """)
        let out = ScriptEngine().transform(response, for: request, with: [script])
        #expect(out.value.status == 201)
        #expect(String(decoding: out.value.body, as: UTF8.self) == #"{"name":"ANA"}"#)
        #expect(out.value.headers.filter { $0.name == "Set-Cookie" }.count == 2)
    }

    @Test func gzipBodyIsDecodedForTheScriptAndLeftAloneIfUntouched() throws {
        var gz = response
        gz.headers.append(HTTPHeader(name: "Content-Encoding", value: "gzip"))
        gz.body = Data([0x1f, 0x8b, 0, 0])      // not valid gzip: stays as-is for the script
        let script = ProxioScript(name: "noop", source: "function onResponse(q, r) { return r; }")
        let out = ScriptEngine().transform(gz, for: request, with: [script])
        #expect(out.value == gz)
        #expect(out.notes.isEmpty)
    }

    @Test func scriptsOnlyRunForMatchingEnabledRequests() {
        let engine = ScriptEngine()
        let src = #"function onRequest(r) { r.headers["X-Hit"] = "1"; return r; }"#
        let other = ProxioScript(name: "other", matcher: RequestMatcher(urlPattern: "other.com"), source: src)
        let off = ProxioScript(name: "off", isEnabled: false, source: src)
        #expect(engine.transform(request, with: [other, off]).value == request)
        let hit = ProxioScript(name: "hit", matcher: RequestMatcher(method: "GET", urlPattern: "api.example.com/v1/*"), source: src)
        #expect(engine.transform(request, with: [hit]).value.headers.contains(HTTPHeader(name: "X-Hit", value: "1")))
    }

    @Test func errorsLeaveTrafficUntouchedAndAreReported() {
        let engine = ScriptEngine()
        let broken = ProxioScript(name: "broken", source: "function onRequest(r) { return r.nope.x; }")
        let out = engine.transform(request, with: [broken])
        #expect(out.value == request)
        #expect(out.notes.first?.hasPrefix("Script broken failed:") == true)
        let syntax = ProxioScript(name: "syntax", source: "function onRequest(r) {")
        #expect(engine.transform(request, with: [syntax]).notes.first?.hasPrefix("Script syntax failed:") == true)
    }

    @Test func consoleLogReachesTheHandler() {
        let engine = ScriptEngine()
        let box = LogBox()
        engine.onLog = { name, text in box.add("\(name): \(text)") }
        _ = engine.transform(request, with: [ProxioScript(name: "log", source: #"function onRequest(r) { console.log("host", 42, r.method); }"#)])
        #expect(box.items == ["log: host 42 GET"])
    }

    @Test func rulesDocumentFromBeforeScriptingStillLoads() throws {
        let old = Data(#"{"breakpoints":[],"mapLocal":[],"mapRemote":[]}"#.utf8)
        let doc = try JSONDecoder().decode(RulesDocument.self, from: old)
        #expect(doc.scripts.isEmpty)
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock(); private var _items: [String] = []
    func add(_ s: String) { lock.withLock { _items.append(s) } }
    var items: [String] { lock.withLock { _items } }
}
