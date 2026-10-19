import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import ProxioCore

/// Local HTTP proxy. Plain HTTP requests are forwarded and recorded; CONNECT
/// requests are tunnelled as opaque bytes (TLS interception comes later).
public final class ProxyServer: @unchecked Sendable {
    private let environment: ProxyEnvironment
    private let host: String
    private let requestedPort: Int
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    /// - Parameters:
    ///   - ca: when set, CONNECT tunnels are intercepted (TLS terminated and re-originated); otherwise they are relayed opaquely.
    ///   - sslProxying: which hosts are intercepted when `ca` is set; the rest are tunnelled opaquely. Can be changed while running.
    ///   - rules: live breakpoints (and later rewrite rules) applied to each request and response.
    ///   - upstreamTLS: client TLS settings used to reach origin servers when intercepting.
    public init(
        store: FlowStore,
        host: String = "127.0.0.1",
        port: Int = 9090,
        ca: CertificateAuthority? = nil,
        upstreamTLS: TLSConfiguration? = nil,
        sslProxying: SSLProxyingPolicy = SSLProxyingPolicy(),
        rules: TrafficRules = TrafficRules(),
        threads: Int = System.coreCount
    ) throws {
        var tls = upstreamTLS ?? TLSConfiguration.makeClientConfiguration()
        tls.applicationProtocols = ["http/1.1"]
        let http1 = try NIOSSLContext(configuration: tls)
        tls.applicationProtocols = ["h2", "http/1.1"]
        self.environment = ProxyEnvironment(store: store, ca: ca, sslProxying: sslProxying, upstreamSSLContext: http1, upstreamH2SSLContext: try NIOSSLContext(configuration: tls), rules: rules)
        self.host = host
        self.requestedPort = port
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, threads))
    }

    /// Starts listening and returns the bound port (useful with port 0).
    @discardableResult
    public func start() async throws -> Int {
        let environment = self.environment
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                    HTTPResponseEncoder(),
                    HTTPServerPipelineHandler(),
                    ProxyFrontendHandler(environment: environment),
                ])
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let ch = try await bootstrap.bind(host: host, port: requestedPort).get()
        channel = ch
        return ch.localAddress?.port ?? requestedPort
    }

    public func stop() async throws {
        environment.pool.closeAll()
        try await channel?.close().get()
        channel = nil
        try await group.shutdownGracefully()
    }
}
