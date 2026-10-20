import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOConcurrencyHelpers
import ProxioCore
@testable import ProxioProxy

private final class OriginOK: ChannelInboundHandler {
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

/// A minimal CONNECT proxy that tunnels every request to a fixed local origin.
private final class FakeProxy: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let originPort: Int
    private let group: EventLoopGroup
    private let lock = NIOLock()
    private var _seen: [String] = []
    private var tunnelled = false
    var seen: [String] { lock.withLock { _seen } }

    init(originPort: Int, group: EventLoopGroup) { self.originPort = originPort; self.group = group }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !tunnelled else { return }
        tunnelled = true
        let text = String(buffer: unwrapInboundIn(data))
        lock.withLock { _seen = text.components(separatedBy: "\r\n").filter { !$0.isEmpty } }
        let client = context.channel
        ClientBootstrap(group: group).connect(host: "127.0.0.1", port: originPort).whenSuccess { origin in
            _ = client.pipeline.removeHandler(self)
                .flatMap { client.pipeline.addHandler(RelayHandler(peer: origin)) }
                .flatMap { origin.pipeline.addHandler(RelayHandler(peer: client)) }
                .flatMap { client.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n")) }
        }
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

@Suite struct ExternalProxyTests {
    @Test func decidesWhichHostsGoThroughTheProxy() {
        var proxy = ExternalProxy(isEnabled: true, host: "proxy.corp", port: 3128, bypass: "*.corp.test, intranet")
        #expect(proxy.applies(to: "example.com"))
        #expect(!proxy.applies(to: "api.corp.test"))
        #expect(!proxy.applies(to: "intranet"))
        #expect(!proxy.applies(to: "localhost"))
        #expect(!proxy.applies(to: "127.0.0.1"))
        proxy.isEnabled = false
        #expect(!proxy.applies(to: "example.com"))
        #expect(ExternalProxy(username: "u", password: "p").authorization == "Basic dTpw")
    }

    @Test func forwardsThroughConnectWithCredentials() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let origin = try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in ch.pipeline.configureHTTPServerPipeline().flatMap { ch.pipeline.addHandler(OriginOK()) } }
            .bind(host: "127.0.0.1", port: 0).get()
        let originPort = origin.localAddress!.port!
        let fake = FakeProxy(originPort: originPort, group: group)
        let external = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(fake) }
            .bind(host: "127.0.0.1", port: 0).get()

        let store = FlowStore()
        let rules = TrafficRules()
        rules.externalProxy = ExternalProxy(isEnabled: true, host: "127.0.0.1", port: external.localAddress!.port!, username: "u", password: "p", bypass: "")
        let proxy = try ProxyServer(store: store, port: 0, rules: rules, threads: 1)
        let proxyPort = try await proxy.start()

        let box = Collector()
        let client = try await ClientBootstrap(group: group).channelInitializer { $0.pipeline.addHandler(box) }
            .connect(host: "127.0.0.1", port: proxyPort).get()
        try await client.writeAndFlush(ByteBuffer(string: "GET http://via-proxy.invalid:\(originPort)/ HTTP/1.1\r\nHost: via-proxy.invalid\r\nConnection: close\r\n\r\n")).get()
        for _ in 0..<300 where !box.value.hasSuffix("ok") { try await Task.sleep(nanoseconds: 10_000_000) }

        #expect(box.value.hasPrefix("HTTP/1.1 200") && box.value.hasSuffix("ok"))
        #expect(fake.seen.first == "CONNECT via-proxy.invalid:\(originPort) HTTP/1.1")
        #expect(fake.seen.contains("Proxy-Authorization: Basic dTpw"))

        try await proxy.stop()
        try await external.close().get()
        try await origin.close().get()
        try await group.shutdownGracefully()
    }
}
