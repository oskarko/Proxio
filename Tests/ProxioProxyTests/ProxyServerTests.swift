import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import ProxioCore
@testable import ProxioProxy

/// Minimal upstream: answers every request with "hello" and echoes the path in a header.
private final class HelloHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var uri = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): uri = h.uri
        case .body: break
        case .end:
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain")
            headers.add(name: "Content-Length", value: "5")
            headers.add(name: "X-Path", value: uri)
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: 5)
            buf.writeString("hello")
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }
    }
}

private func startUpstream(_ group: EventLoopGroup) async throws -> Channel {
    try await ServerBootstrap(group: group)
        .childChannelInitializer { ch in ch.pipeline.configureHTTPServerPipeline().flatMap { ch.pipeline.addHandler(HelloHandler()) } }
        .bind(host: "127.0.0.1", port: 0).get()
}

/// Collects raw bytes received on a client connection.
private final class Collector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<String>
    private var text = ""
    init(_ promise: EventLoopPromise<String>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { text += String(buffer: unwrapInboundIn(data)) }
    func channelInactive(context: ChannelHandlerContext) { promise.succeed(text) }
}

@Test func forwardsPlainHTTPAndRecordsFlow() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await startUpstream(group)
    let upstreamPort = upstream.localAddress!.port!

    let store = FlowStore()
    let proxy = ProxyServer(store: store, port: 0)
    let proxyPort = try await proxy.start()

    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
    ]
    let session = URLSession(configuration: config)
    let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(upstreamPort)/ping?x=1")!)

    #expect(String(data: data, encoding: .utf8) == "hello")
    #expect((response as? HTTPURLResponse)?.statusCode == 200)

    try await Task.sleep(nanoseconds: 200_000_000)
    let flows = await store.all()
    #expect(flows.count == 1)
    #expect(flows.first?.request.url.path == "/ping")
    #expect(flows.first?.request.url.query == "x=1")
    #expect(flows.first?.response?.status == 200)
    #expect(flows.first?.response?.mimeType == "text/plain")
    #expect(flows.first?.response.flatMap { String(data: $0.body, encoding: .utf8) } == "hello")

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}

@Test func tunnelsConnectAndRecordsIt() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await startUpstream(group)
    let upstreamPort = upstream.localAddress!.port!

    let store = FlowStore()
    let proxy = ProxyServer(store: store, port: 0)
    let proxyPort = try await proxy.start()

    let done = group.next().makePromise(of: String.self)
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { $0.pipeline.addHandler(Collector(done)) }
        .connect(host: "127.0.0.1", port: proxyPort).get()

    let connect = "CONNECT 127.0.0.1:\(upstreamPort) HTTP/1.1\r\nHost: 127.0.0.1:\(upstreamPort)\r\n\r\n"
    try await client.writeAndFlush(ByteBuffer(string: connect)).get()
    try await Task.sleep(nanoseconds: 300_000_000)
    let inner = "GET /tunnel HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    try await client.writeAndFlush(ByteBuffer(string: inner)).get()

    let received = try await done.futureResult.get()
    #expect(received.hasPrefix("HTTP/1.1 200 Connection Established"))
    #expect(received.contains("X-Path: /tunnel"))
    #expect(received.hasSuffix("hello"))

    let flows = await store.all()
    #expect(flows.first?.request.method == "CONNECT")

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}

@Test func rejectsUnreachableUpstreamWith502() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let proxy = ProxyServer(store: FlowStore(), port: 0)
    let proxyPort = try await proxy.start()

    let done = group.next().makePromise(of: String.self)
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { $0.pipeline.addHandler(Collector(done)) }
        .connect(host: "127.0.0.1", port: proxyPort).get()
    try await client.writeAndFlush(ByteBuffer(string: "CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n")).get()
    #expect(try await done.futureResult.get().hasPrefix("HTTP/1.1 502"))

    try await proxy.stop()
    try await group.shutdownGracefully()
}

@Test func parsesHostAndPort() {
    #expect(ProxyFrontendHandler.hostPort(from: "example.com:8443", defaultPort: 443)! == ("example.com", 8443))
    #expect(ProxyFrontendHandler.hostPort(from: "example.com", defaultPort: 443)! == ("example.com", 443))
    #expect(ProxyFrontendHandler.hostPort(from: ":80", defaultPort: 443) == nil)
}
