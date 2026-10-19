import Testing
import Foundation
@testable import ProxioCore

@Test func matcherHandlesMethodHostAndPathGlobs() {
    let url = URL(string: "https://api.example.com:8443/v1/users?id=7")!
    #expect(RequestMatcher(urlPattern: "").matches(method: "GET", url: url))
    #expect(RequestMatcher(urlPattern: "api.example.com:8443").matches(method: "GET", url: url))
    #expect(RequestMatcher(urlPattern: "*.example.com*").matches(method: "GET", url: url))
    #expect(RequestMatcher(urlPattern: "api.example.com:8443/v1/*").matches(method: "GET", url: url))
    #expect(RequestMatcher(urlPattern: "https://api.example.com:8443/v1/users?id=*").matches(method: "GET", url: url))
    #expect(!RequestMatcher(urlPattern: "api.example.com:8443/v2/*").matches(method: "GET", url: url))
    #expect(!RequestMatcher(urlPattern: "example.com").matches(method: "GET", url: url))
    #expect(RequestMatcher(method: "get", urlPattern: "*").matches(method: "GET", url: url))
    #expect(!RequestMatcher(method: "POST", urlPattern: "*").matches(method: "GET", url: url))
}

@Test func hostOnlyPatternDoesNotMatchLongerHosts() {
    let url = URL(string: "http://example.community/")!
    #expect(!RequestMatcher(urlPattern: "example.com").matches(method: "GET", url: url))
    #expect(RequestMatcher(urlPattern: "example.com").matches(method: "GET", url: URL(string: "http://example.com")!))
}

private struct NoopHandler: BreakpointHandler {
    func resume(request: HTTPRequestRecord) async -> HTTPRequestRecord? { request }
    func resume(response: HTTPResponseRecord, for request: HTTPRequestRecord) async -> HTTPResponseRecord? { response }
}

@Test func rulesOnlyPauseWhenEnabledAndPhaseMatches() {
    let rules = TrafficRules()
    let request = HTTPRequestRecord(method: "GET", url: URL(string: "http://example.com/a")!)
    #expect(rules.breakpointHandler(request: request, phase: .request) == nil)

    rules.breakpointHandler = NoopHandler()
    rules.breakpoints = [Breakpoint(matcher: RequestMatcher(urlPattern: "example.com"), onRequest: false, onResponse: true)]
    #expect(rules.breakpointHandler(request: request, phase: .request) == nil)
    #expect(rules.breakpointHandler(request: request, phase: .response) != nil)

    rules.breakpoints[0].isEnabled = false
    #expect(rules.breakpointHandler(request: request, phase: .response) == nil)
}

@Test func mapRemoteRewritesOnlyTheConfiguredParts() {
    let url = URL(string: "https://api.example.com/v1/users?id=7")!
    let rule = MapRemoteRule(matcher: RequestMatcher(urlPattern: "api.example.com"), scheme: "http", host: "localhost", port: 3000, path: "/mock")
    #expect(rule.rewritten(url)?.absoluteString == "http://localhost:3000/mock?id=7")

    let hostOnly = MapRemoteRule(matcher: RequestMatcher(urlPattern: "*"), host: "staging.example.com")
    #expect(hostOnly.rewritten(url)?.absoluteString == "https://staging.example.com/v1/users?id=7")
}

@Test func rulesPickTheFirstEnabledMatch() {
    let rules = TrafficRules()
    let request = HTTPRequestRecord(method: "GET", url: URL(string: "http://example.com/a")!)
    rules.mapLocalRules = [
        MapLocalRule(isEnabled: false, matcher: RequestMatcher(urlPattern: "*"), status: 500),
        MapLocalRule(matcher: RequestMatcher(urlPattern: "example.com"), status: 201),
    ]
    #expect(rules.mapLocal(for: request)?.status == 201)
    #expect(rules.mapLocal(for: HTTPRequestRecord(method: "GET", url: URL(string: "http://other.com/")!)) == nil)

    rules.mapRemoteRules = [MapRemoteRule(matcher: RequestMatcher(urlPattern: "example.com"), host: "example.com")]
    #expect(rules.mapRemote(for: request) == nil)   // rewriting to the same URL is not a change
}

@Test func mapLocalBuildsResponsesFromBodyAndFile() throws {
    let inline = MapLocalRule(matcher: RequestMatcher(urlPattern: "*"), status: 404, body: Data(#"{"ok":false}"#.utf8)).makeResponse()
    #expect(inline.status == 404)
    #expect(inline.reason == "Not Found")
    #expect(inline.mimeType == "application/json")

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("proxio-\(UUID().uuidString).html")
    try Data("<h1>hi</h1>".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let fromFile = MapLocalRule(matcher: RequestMatcher(urlPattern: "*"), filePath: file.path).makeResponse()
    #expect(fromFile.mimeType == "text/html")
    #expect(String(data: fromFile.body, encoding: .utf8) == "<h1>hi</h1>")

    let missing = MapLocalRule(matcher: RequestMatcher(urlPattern: "*"), filePath: "/nonexistent/file.json").makeResponse()
    #expect(missing.status == 500)
}

@Test func headerTextRoundTripsAndSkipsJunk() {
    let headers = [HTTPHeader(name: "Accept", value: "*/*"), HTTPHeader(name: "X-Time", value: "10:30:00")]
    #expect(HeaderText.parse(HeaderText.format(headers)) == headers)
    #expect(HeaderText.parse("no colon here\n: empty name\n  X-A :  1  ") == [HTTPHeader(name: "X-A", value: "1")])
}

private func tempRulesURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("proxio-\(UUID().uuidString)/rules.json")
}

@Test func rulesStoreRoundTripsEveryRuleKind() throws {
    let store = RulesStore(url: tempRulesURL())
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    #expect(store.load() == RulesDocument())   // missing file

    let document = RulesDocument(
        breakpoints: [Breakpoint(matcher: RequestMatcher(method: "POST", urlPattern: "api.example.com/*"), onResponse: false)],
        mapLocal: [MapLocalRule(matcher: RequestMatcher(urlPattern: "*"), status: 418, headers: [HTTPHeader(name: "X-A", value: "1")], body: Data([0, 1, 2, 255]), filePath: "~/x.json")],
        mapRemote: [MapRemoteRule(matcher: RequestMatcher(urlPattern: "a.com"), scheme: "http", host: "localhost", port: 3000, path: "/m")]
    )
    try store.save(document)
    #expect(store.load() == document)
}

@Test func corruptRulesAreKeptAsBackupInsteadOfOverwritten() throws {
    let store = RulesStore(url: tempRulesURL())
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: store.url)

    #expect(store.load() == RulesDocument())
    #expect(!FileManager.default.fileExists(atPath: store.url.path))
    #expect(try Data(contentsOf: store.url.appendingPathExtension("bak")) == Data("{ not json".utf8))
}
