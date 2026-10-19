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
