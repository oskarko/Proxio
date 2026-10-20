import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOConcurrencyHelpers
import ProxioCore
@testable import ProxioProxy

private final class BigBodyHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let size: Int
    init(size: Int) { self.size = size }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(size))
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(repeating: 0x61, count: size)))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private final class Counter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NIOLock()
    private var bytes = 0
    var count: Int { lock.withLock { bytes } }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let n = unwrapInboundIn(data).readableBytes
        lock.withLock { bytes += n }
    }
}

private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@Test func throttleAddsLatencyPacesBandwidthAndGoesOffline() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await ServerBootstrap(group: group)
        .childChannelInitializer { ch in ch.pipeline.configureHTTPServerPipeline().flatMap { ch.pipeline.addHandler(BigBodyHandler(size: 40_000)) } }
        .bind(host: "127.0.0.1", port: 0).get()
    let upstreamPort = upstream.localAddress!.port!

    let conditions = NetworkConditions()
    let proxy = try ProxyServer(store: FlowStore(), port: 0, conditions: conditions, threads: 1)
    let proxyPort = try await proxy.start()
    let request = "GET http://127.0.0.1:\(upstreamPort)/ HTTP/1.1\r\nHost: x\r\n\r\n"

    func timeOneRequest() async throws -> TimeInterval {
        let counter = Counter()
        let client = try await ClientBootstrap(group: group).channelInitializer { $0.pipeline.addHandler(counter) }
            .connect(host: "127.0.0.1", port: proxyPort).get()
        let start = Date()
        try await client.writeAndFlush(ByteBuffer(string: request)).get()
        let done = await waitFor(10) { counter.count >= 40_000 }
        let elapsed = Date().timeIntervalSince(start)
        try await client.close().get()
        #expect(done)
        return elapsed
    }

    let baseline = try await timeOneRequest()
    #expect(baseline < 0.3)

    // 300 ms round trip: at least that long before the first byte of the answer can arrive.
    conditions.profile = NetworkProfile(name: "lat", latencyMs: 300)
    let slow = try await timeOneRequest()
    #expect(slow >= 0.28)

    // 40 000 bytes at 320 kbit/s (40 000 B/s) take about a second.
    conditions.profile = NetworkProfile(name: "bw", downKbps: 320)
    let paced = try await timeOneRequest()
    #expect(paced >= 0.9 && paced < 3)

    // Offline: the connection is refused straight away.
    conditions.profile = .offlineProfile
    let client = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: proxyPort).get()
    #expect(await waitFor(2) { !client.isActive })

    // Back to normal without restarting.
    conditions.profile = .none
    #expect(try await timeOneRequest() < 0.3)

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}
