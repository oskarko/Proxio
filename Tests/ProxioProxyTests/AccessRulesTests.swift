import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOConcurrencyHelpers
import ProxioCore
@testable import ProxioProxy

private final class OKHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "2")
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "ok")))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private final class Collector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NIOLock()
    private var text = ""
    var value: String { lock.withLock { text } }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let chunk = String(buffer: unwrapInboundIn(data))
        lock.withLock { text += chunk }
    }
}

@Suite struct AccessRulesTests {
    @Test func blockAllowDNSAndBypassDecisions() {
        let rules = TrafficRules()
        let get = HTTPRequestRecord(method: "GET", url: URL(string: "https://ads.example.com/banner.js")!)
        #expect(rules.blockReason(for: get) == nil)

        rules.blockRules = [AccessRule(matcher: RequestMatcher(urlPattern: "ads.example.com"))]
        #expect(rules.blockReason(for: get) == "Blocked")
        #expect(rules.blockReason(forTunnelTo: "ads.example.com", port: 443) == "Blocked")
        #expect(rules.blockReason(forTunnelTo: "www.example.com", port: 443) == nil)

        rules.blockRules = []
        rules.allowRules = [AccessRule(matcher: RequestMatcher(urlPattern: "*.corp.test"))]
        #expect(rules.blockReason(for: get) == "Not in Allow List")
        #expect(rules.blockReason(for: HTTPRequestRecord(method: "GET", url: URL(string: "https://api.corp.test/x")!)) == nil)
        #expect(rules.blockReason(forTunnelTo: "api.corp.test", port: 443) == nil)
        #expect(rules.blockReason(forTunnelTo: "other.test", port: 443) == "Not in Allow List")

        rules.dnsRules = [DNSRule(hostPattern: "*.staging.test", address: "10.0.0.5")]
        #expect(rules.dnsOverride(for: "api.staging.test") == "10.0.0.5")
        #expect(rules.dnsOverride(for: "api.prod.test") == nil)

        rules.bypassRules = [BypassRule(hostPattern: "*.apple.com")]
        #expect(rules.isBypassed(host: "gsa.apple.com", port: 443))
        #expect(!rules.isBypassed(host: "example.com", port: 443))
    }

    @Test func proxyAnswers403ForBlockedAndConnectsToSpoofedAddress() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let upstream = try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in ch.pipeline.configureHTTPServerPipeline().flatMap { ch.pipeline.addHandler(OKHandler()) } }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = upstream.localAddress!.port!

        let store = FlowStore()
        let rules = TrafficRules()
        rules.blockRules = [AccessRule(matcher: RequestMatcher(urlPattern: "blocked.invalid"))]
        rules.dnsRules = [DNSRule(hostPattern: "spoofed.invalid", address: "127.0.0.1")]
        let proxy = try ProxyServer(store: store, port: 0, rules: rules, threads: 1)
        let proxyPort = try await proxy.start()

        func get(_ host: String) async throws -> String {
            let box = Collector()
            let client = try await ClientBootstrap(group: group).channelInitializer { $0.pipeline.addHandler(box) }
                .connect(host: "127.0.0.1", port: proxyPort).get()
            try await client.writeAndFlush(ByteBuffer(string: "GET http://\(host):\(port)/ HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n")).get()
            for _ in 0..<200 where !box.value.contains("\r\n\r\n") || client.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
            return box.value
        }

        #expect(try await get("blocked.invalid").hasPrefix("HTTP/1.1 403"))
        let spoofed = try await get("spoofed.invalid")
        #expect(spoofed.hasPrefix("HTTP/1.1 200") && spoofed.hasSuffix("ok"))

        try await Task.sleep(nanoseconds: 100_000_000)
        let flows = await store.all()
        #expect(flows.first { $0.request.url.host == "blocked.invalid" }?.notes == ["Blocked"])
        #expect(flows.first { $0.request.url.host == "spoofed.invalid" }?.response?.status == 200)

        try await proxy.stop()
        try await upstream.close().get()
        try await group.shutdownGracefully()
    }
}
