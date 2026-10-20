import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import ProxioCore

/// Opens a connection to an origin, directly or through the configured external HTTP proxy (CONNECT tunnel).
enum UpstreamDialer {
    static func dial(host: String, port: Int, via proxy: ExternalProxy?, loop: EventLoop) -> EventLoopFuture<Channel> {
        guard let proxy else { return ClientBootstrap(group: loop).connect(host: host, port: port) }
        let established = loop.makePromise(of: Void.self)
        let connected = ClientBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        HTTPRequestEncoder(),
                        ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                        ConnectHandshake(promise: established),
                    ])
                }
            }
            .connect(host: proxy.host, port: proxy.port)
        connected.whenFailure { established.fail($0) }
        return connected
            .flatMap { channel -> EventLoopFuture<Channel> in
                let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(port)" : "\(host):\(port)"
                var headers = HTTPHeaders([("Host", authority), ("Proxy-Connection", "keep-alive")])
                if let auth = proxy.authorization { headers.add(name: "Proxy-Authorization", value: auth) }
                channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: authority, headers: headers)), promise: nil)
                channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                return established.futureResult.flatMap { _ in
                    let pipeline = channel.pipeline
                    return pipeline.handler(type: ConnectHandshake.self).flatMap { pipeline.removeHandler($0) }
                        .flatMap { _ in pipeline.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self) }.flatMap { pipeline.removeHandler($0) }
                        .flatMap { _ in pipeline.handler(type: HTTPRequestEncoder.self) }.flatMap { pipeline.removeHandler($0) }
                        .map { channel }
                }
                .flatMapError { error in channel.close(promise: nil); return channel.eventLoop.makeFailedFuture(error) }
            }
    }

    enum DialError: Error { case proxyRefused(Int) }

    /// Waits for the proxy's answer to CONNECT. The head is enough: a 2xx reply has no body.
    private final class ConnectHandshake: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPClientResponsePart
        private var promise: EventLoopPromise<Void>?
        init(promise: EventLoopPromise<Void>) { self.promise = promise }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .head(let head) = unwrapInboundIn(data), let promise else { return }
            self.promise = nil
            if (200..<300).contains(Int(head.status.code)) { promise.succeed(()) } else { promise.fail(DialError.proxyRefused(Int(head.status.code))) }
        }

        func channelInactive(context: ChannelHandlerContext) {
            promise?.fail(ChannelError.ioOnClosedChannel)
            promise = nil
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            promise?.fail(error)
            promise = nil
            context.close(promise: nil)
        }
    }
}
