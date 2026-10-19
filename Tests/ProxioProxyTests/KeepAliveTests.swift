import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOConcurrencyHelpers
import ProxioCore
@testable import ProxioProxy

/// Answers every request with a fixed-length body and keeps the connection open.
private final class KeepOpenHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var uri = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): uri = h.uri
        case .body: break
        case .end:
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "5")
            headers.add(name: "X-Path", value: uri)
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "hello")))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private final class TextBox: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NIOLock()
    private var text = ""
    var value: String { lock.withLock { text } }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let chunk = String(buffer: unwrapInboundIn(data))
        lock.withLock { text += chunk }
    }
}

private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@Test func clientConnectionIsReusedAcrossRequests() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await ServerBootstrap(group: group)
        .childChannelInitializer { ch in ch.pipeline.configureHTTPServerPipeline().flatMap { ch.pipeline.addHandler(KeepOpenHandler()) } }
        .bind(host: "127.0.0.1", port: 0).get()
    let upstreamPort = upstream.localAddress!.port!

    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0)
    let proxyPort = try await proxy.start()

    let box = TextBox()
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { $0.pipeline.addHandler(box) }
        .connect(host: "127.0.0.1", port: proxyPort).get()

    func request(_ path: String) -> String {
        "GET http://127.0.0.1:\(upstreamPort)\(path) HTTP/1.1\r\nHost: 127.0.0.1:\(upstreamPort)\r\n\r\n"
    }
    // Sequential: each answer arrives before the next request goes out.
    for (n, path) in ["/one", "/two"].enumerated() {
        try await client.writeAndFlush(ByteBuffer(string: request(path))).get()
        #expect(await waitUntil { box.value.components(separatedBy: "HTTP/1.1 200").count - 1 == n + 1 })
    }
    // Pipelined: two requests in one write are answered in order.
    try await client.writeAndFlush(ByteBuffer(string: request("/three") + request("/four"))).get()
    #expect(await waitUntil { box.value.components(separatedBy: "HTTP/1.1 200").count - 1 == 4 })

    let text = box.value
    let order = ["/one", "/two", "/three", "/four"].compactMap { text.range(of: "X-Path: \($0)")?.lowerBound }
    #expect(order.count == 4 && order == order.sorted())
    #expect(text.contains("Connection: keep-alive"))
    #expect(client.isActive)

    #expect(await waitUntil { true })
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(await store.all().count == 4)

    // A client that asks to close gets the connection closed after the answer.
    try await client.writeAndFlush(ByteBuffer(string: "GET http://127.0.0.1:\(upstreamPort)/bye HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")).get()
    #expect(await waitUntil { !client.isActive })

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}
