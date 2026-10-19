import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import ProxioCore

/// Local HTTP proxy. Plain HTTP requests are forwarded and recorded; CONNECT
/// requests are tunnelled as opaque bytes (TLS interception comes later).
public final class ProxyServer: @unchecked Sendable {
    private let store: FlowStore
    private let host: String
    private let requestedPort: Int
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(store: FlowStore, host: String = "127.0.0.1", port: Int = 9090) {
        self.store = store
        self.host = host
        self.requestedPort = port
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    /// Starts listening and returns the bound port (useful with port 0).
    @discardableResult
    public func start() async throws -> Int {
        let store = self.store
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                    HTTPResponseEncoder(),
                    ProxyFrontendHandler(store: store),
                ])
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let ch = try await bootstrap.bind(host: host, port: requestedPort).get()
        channel = ch
        return ch.localAddress?.port ?? requestedPort
    }

    public func stop() async throws {
        try await channel?.close().get()
        channel = nil
        try await group.shutdownGracefully()
    }
}
