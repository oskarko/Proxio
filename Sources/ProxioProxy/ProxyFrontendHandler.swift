import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import ProxioCore

struct ProxyEnvironment {
    let store: FlowStore
    let ca: CertificateAuthority?
    let upstreamSSLContext: NIOSSLContext
}

/// Handles one client connection: reads a request, then either forwards it
/// (plain HTTP), intercepts it (CONNECT with a CA) or opens an opaque tunnel.
/// Inside an intercepted tunnel a fresh instance handles the decrypted requests.
final class ProxyFrontendHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let env: ProxyEnvironment
    private let tunnel: (host: String, port: Int)?
    private var head: HTTPRequestHead?
    private var body = Data()
    private var startedAt = Date()

    init(environment: ProxyEnvironment, tunnel: (host: String, port: Int)? = nil) {
        self.env = environment
        self.tunnel = tunnel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body = Data()
            startedAt = Date()
            if h.method == .CONNECT { connect(context: context, head: h) }
        case .body(let buf):
            if head?.method != .CONNECT { body.append(contentsOf: buf.readableBytesView) }
        case .end:
            if let h = head, h.method != .CONNECT { forward(context: context, head: h) }
        }
    }

    // MARK: CONNECT

    private func connect(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard let (host, port) = Self.hostPort(from: head.uri, defaultPort: 443) else {
            return fail(context: context, status: .badRequest)
        }
        if let ca = env.ca, let sslContext = try? ca.serverContext(for: host) {
            return intercept(context: context, host: host, port: port, sslContext: sslContext)
        }
        let client = context.channel
        let store = env.store
        let started = startedAt
        ClientBootstrap(group: context.eventLoop)
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case .failure:
                    self.fail(context: context, status: .badGateway)
                case .success(let upstream):
                    let record = Flow(
                        startedAt: started,
                        duration: Date().timeIntervalSince(started),
                        request: HTTPRequestRecord(method: "CONNECT", url: URL(string: "https://\(host):\(port)")!),
                        response: HTTPResponseRecord(status: 200, reason: "Connection Established")
                    )
                    Task { await store.add(record) }

                    // A 2xx CONNECT reply has no body framing, so it is written raw,
                    // after the HTTP codec is gone and the relays are in place.
                    let pipeline = client.pipeline
                    _ = pipeline.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self).flatMap { pipeline.removeHandler($0) }
                        .flatMap { _ in pipeline.handler(type: HTTPResponseEncoder.self) }.flatMap { pipeline.removeHandler($0) }
                        .flatMap { pipeline.removeHandler(self) }
                        .flatMap { pipeline.addHandler(RelayHandler(peer: upstream)) }
                        .flatMap { upstream.pipeline.addHandler(RelayHandler(peer: client)) }
                        .flatMap { client.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n")) }
                        .flatMapError { _ in client.close(); return upstream.close() }
                }
            }
    }

    /// Answers the CONNECT, then terminates TLS locally and parses the decrypted HTTP.
    private func intercept(context: ChannelHandlerContext, host: String, port: Int, sslContext: NIOSSLContext) {
        let client = context.channel
        let started = startedAt
        let record = Flow(
            startedAt: started,
            request: HTTPRequestRecord(method: "CONNECT", url: URL(string: "https://\(host):\(port)")!),
            response: HTTPResponseRecord(status: 200, reason: "Connection Established")
        )
        let store = env.store
        Task { await store.add(record) }

        let env = self.env
        let pipeline = client.pipeline
        _ = pipeline.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self).flatMap { pipeline.removeHandler($0) }
            .flatMap { _ in pipeline.handler(type: HTTPResponseEncoder.self) }.flatMap { pipeline.removeHandler($0) }
            .flatMap { _ -> EventLoopFuture<Void> in
                // Same event-loop turn: the reply goes out in clear, the TLS layer is installed before any ClientHello can be read.
                client.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n"), promise: nil)
                return pipeline.addHandlers([
                    NIOSSLServerHandler(context: sslContext),
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)),
                    HTTPResponseEncoder(),
                    ProxyFrontendHandler(environment: env, tunnel: (host, port)),
                ], position: .before(self))
            }
            .flatMap { pipeline.removeHandler(self) }
            .whenFailure { _ in client.close(promise: nil) }
    }

    // MARK: Forwarding (plain HTTP, or decrypted HTTPS inside a tunnel)

    private func forward(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let url: URL, host: String, port: Int, path: String
        if let tunnel {
            host = tunnel.host
            port = tunnel.port
            guard let u = URL(string: "https://\(host)\(port == 443 ? "" : ":\(port)")\(head.uri)") else {
                return fail(context: context, status: .badRequest)
            }
            url = u
            path = head.uri
        } else {
            guard let u = URL(string: head.uri), let h = u.host, u.scheme == "http" else {
                return fail(context: context, status: .badRequest)
            }
            url = u
            host = h
            port = u.port ?? 80
            var p = u.path.isEmpty ? "/" : u.path
            if let q = u.query { p += "?\(q)" }
            path = p
        }

        var upstreamHead = HTTPRequestHead(version: .http1_1, method: head.method, uri: path)
        upstreamHead.headers = head.headers
        upstreamHead.headers.remove(name: "Proxy-Connection")
        upstreamHead.headers.replaceOrAdd(name: "Connection", value: "close")
        if !upstreamHead.headers.contains(name: "Host") {
            upstreamHead.headers.add(name: "Host", value: url.port.map { "\(host):\($0)" } ?? host)
        }

        let request = HTTPRequestRecord(
            method: head.method.rawValue, url: url,
            headers: head.headers.map { HTTPHeader(name: $0.name, value: $0.value) },
            body: body
        )
        let flow = Flow(startedAt: startedAt, request: request)
        let bodyData = body
        let client = context.channel
        let env = self.env
        let useTLS = tunnel != nil

        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { ch in
                do {
                    var handlers: [ChannelHandler] = []
                    if useTLS {
                        handlers.append(try NIOSSLClientHandler(
                            context: env.upstreamSSLContext,
                            serverHostname: Self.isIPAddress(host) ? nil : host
                        ))
                    }
                    handlers.append(HTTPRequestEncoder())
                    handlers.append(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)))
                    handlers.append(UpstreamResponseHandler(client: client, flow: flow, store: env.store))
                    try ch.pipeline.syncOperations.addHandlers(handlers)
                    return ch.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case .failure:
                    self.fail(context: context, status: .badGateway)
                case .success(let upstream):
                    upstream.write(HTTPClientRequestPart.head(upstreamHead), promise: nil)
                    if !bodyData.isEmpty { upstream.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: bodyData))), promise: nil) }
                    upstream.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                }
            }
    }

    // MARK: Helpers

    private func fail(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }

    static func hostPort(from authority: String, defaultPort: Int) -> (String, Int)? {
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        if parts.count == 1 { return (String(first), defaultPort) }
        guard parts.count == 2, let port = Int(parts[1]) else { return nil }
        return (String(first), port)
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Copies bytes to the peer channel; closing one side closes the other.
final class RelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) { peer.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        peer.close(promise: nil)
    }
}

/// Streams the upstream response to the client while recording a copy.
final class UpstreamResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let client: Channel
    private var flow: Flow
    private let store: FlowStore
    private var response: HTTPResponseRecord?
    private var body = Data()

    init(client: Channel, flow: Flow, store: FlowStore) {
        self.client = client
        self.flow = flow
        self.store = store
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            response = HTTPResponseRecord(
                status: Int(h.status.code), reason: h.status.reasonPhrase,
                headers: h.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
            )
            var headers = h.headers
            headers.replaceOrAdd(name: "Connection", value: "close")
            client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: h.status, headers: headers)), promise: nil)
        case .body(let buf):
            body.append(contentsOf: buf.readableBytesView)
            client.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
        case .end:
            response?.body = body
            flow.response = response
            flow.duration = Date().timeIntervalSince(flow.startedAt)
            let done = flow
            let store = self.store
            Task { await store.add(done) }
            client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [client] _ in client.close(promise: nil) }
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        client.close(promise: nil)
        context.close(promise: nil)
    }
}
