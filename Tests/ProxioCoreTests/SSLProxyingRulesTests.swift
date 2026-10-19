import Testing
@testable import ProxioCore

@Test func hostPatternParsing() {
    #expect(HostPattern("Example.COM")?.host == "example.com")
    #expect(HostPattern("example.com:8443")?.port == 8443)
    #expect(HostPattern("*.example.com")?.host == "*.example.com")
    #expect(HostPattern("*")?.host == "*")
    #expect(HostPattern("") == nil)
    #expect(HostPattern("a*b.com") == nil)
    #expect(HostPattern("example.com:99999") == nil)
    #expect(HostPattern("example.com/path") == nil)
}

@Test func hostPatternMatching() throws {
    let wildcard = try #require(HostPattern("*.example.com"))
    #expect(wildcard.matches(host: "api.example.com", port: 443))
    #expect(wildcard.matches(host: "a.b.example.com", port: 443))
    #expect(!wildcard.matches(host: "example.com", port: 443))
    #expect(!wildcard.matches(host: "badexample.com", port: 443))

    let withPort = try #require(HostPattern("example.com:8443"))
    #expect(withPort.matches(host: "EXAMPLE.com", port: 8443))
    #expect(!withPort.matches(host: "example.com", port: 443))
}

@Test func excludeBeatsIncludeAndDefaultApplies() throws {
    let rules = SSLProxyingRules(
        include: [try #require(HostPattern("*.example.com"))],
        exclude: [try #require(HostPattern("secure.example.com"))],
        interceptByDefault: false
    )
    #expect(rules.shouldIntercept(host: "api.example.com", port: 443))
    #expect(!rules.shouldIntercept(host: "secure.example.com", port: 443))
    #expect(!rules.shouldIntercept(host: "other.org", port: 443))
    #expect(SSLProxyingRules.interceptAll.shouldIntercept(host: "other.org", port: 443))
}

@Test func policyChangesAtRuntime() {
    let policy = SSLProxyingPolicy(.interceptAll)
    policy.rules = .interceptNothing
    #expect(!policy.rules.shouldIntercept(host: "x.com", port: 443))
}
