import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import ProxioCore

struct ProxyEnvironment {
    let store: FlowStore
    let ca: CertificateAuthority?
    let sslProxying: SSLProxyingPolicy
    let upstreamSSLContext: NIOSSLContext
    let rules: TrafficRules
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
        if let ca = env.ca, env.sslProxying.rules.shouldIntercept(host: host, port: port),
           let sslContext = try? ca.serverContext(for: host) {
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

    /// Builds the request record, lets breakpoints edit it, then sends it upstream.
    private func forward(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let url: URL
        if let tunnel {
            let authority = tunnel.port == 443 ? tunnel.host : "\(tunnel.host):\(tunnel.port)"
            guard let u = URL(string: "https://\(authority)\(head.uri)") else {
                return fail(context: context, status: .badRequest)
            }
            url = u
        } else {
            guard let u = URL(string: head.uri), u.host != nil, u.scheme == "http" else {
                return fail(context: context, status: .badRequest)
            }
            url = u
        }
        let request = HTTPRequestRecord(
            method: head.method.rawValue, url: url,
            headers: head.headers.map { HTTPHeader(name: $0.name, value: $0.value) },
            body: body
        )
        var flow = Flow(startedAt: startedAt, request: request)
        let local = env.rules.mapLocal(for: request)
        if local != nil {
            flow.notes.append("Map Local")
        } else if let (rule, rewritten) = env.rules.mapRemote(for: request) {
            flow.request.url = rewritten
            flow.notes.append(rule.summary)
        }
        let scripted = env.rules.applyScripts(to: flow.request)
        flow.request = scripted.value
        flow.notes += scripted.notes

        guard let handler = env.rules.breakpointHandler(request: flow.request, phase: .request) else {
            return proceed(context: context, flow: flow, original: request, local: local)
        }
        let loop = context.eventLoop, paused = flow
        Task {
            let edited = await handler.resume(request: paused.request)
            loop.execute {
                guard let edited else { return self.cancel(context: context, flow: paused) }
                var flow = paused
                flow.request = edited
                self.proceed(context: context, flow: flow, original: request, local: local)
            }
        }
    }

    /// Answers from a Map Local rule, or sends the request upstream.
    private func proceed(context: ChannelHandlerContext, flow: Flow, original: HTTPRequestRecord, local: MapLocalRule?) {
        guard let local else { return send(context: context, flow: flow, original: original) }
        var flow = flow
        let scripted = env.rules.applyScripts(to: local.makeResponse(), for: flow.request)
        flow.notes += scripted.notes
        let response = scripted.value
        let client = context.channel, env = self.env
        guard let handler = env.rules.breakpointHandler(request: flow.request, phase: .response) else {
            return Self.finish(flow, with: response, client: client, store: env.store)
        }
        Task {
            let edited = await handler.resume(response: response, for: flow.request)
            client.eventLoop.execute { Self.finish(flow, with: edited, client: client, store: env.store) }
        }
    }

    /// Records the exchange and writes `response` (nil = cancelled at a breakpoint).
    static func finish(_ flow: Flow, with response: HTTPResponseRecord?, client: Channel, store: FlowStore) {
        var flow = flow
        flow.response = response ?? HTTPResponseRecord(status: 499, reason: "Cancelled by Proxio")
        flow.duration = Date().timeIntervalSince(flow.startedAt)
        let done = flow
        Task { await store.add(done) }
        ResponseWriter.write(response, to: client)
    }

    /// Answers 499 for a request the user cancelled at a breakpoint.
    private func cancel(context: ChannelHandlerContext, flow: Flow) {
        var flow = flow
        flow.response = HTTPResponseRecord(status: 499, reason: "Cancelled by Proxio")
        flow.duration = Date().timeIntervalSince(flow.startedAt)
        let store = env.store, done = flow
        Task { await store.add(done) }
        fail(context: context, status: .custom(code: 499, reasonPhrase: "Cancelled by Proxio"))
    }

    private func send(context: ChannelHandlerContext, flow: Flow, original: HTTPRequestRecord) {
        let request = flow.request
        let url = request.url
        guard let host = url.host, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return fail(context: context, status: .badRequest)
        }
        let useTLS = scheme == "https"
        let port = url.port ?? (useTLS ? 443 : 80)
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let q = components.percentEncodedQuery { path += "?\(q)" }

        var headers = HTTPHeaders()
        for h in request.headers { headers.add(name: h.name, value: h.value) }
        for name in ["Proxy-Connection", "Transfer-Encoding", "Content-Length", "Connection"] { headers.remove(name: name) }
        if Self.isWebSocketUpgrade(request) {
            headers.add(name: "Connection", value: "Upgrade")
            headers.remove(name: "Sec-WebSocket-Extensions")   // no permessage-deflate: frames stay readable
        } else {
            headers.add(name: "Connection", value: "close")
        }
        if !request.body.isEmpty || ["POST", "PUT", "PATCH"].contains(request.method.uppercased()) {
            headers.add(name: "Content-Length", value: String(request.body.count))
        }
        if env.rules.breakpointHandler(request: request, phase: .response) != nil || env.rules.hasScripts(for: request) {
            headers.replaceOrAdd(name: "Accept-Encoding", value: "identity")   // keep the held body editable
        }
        let authority = url.port.map { "\(host):\($0)" } ?? host
        if !headers.contains(name: "Host") || original.url.host != url.host || original.url.port != url.port {
            headers.replaceOrAdd(name: "Host", value: authority)
        }
        let upstreamHead = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method), uri: path, headers: headers)

        let bodyData = request.body
        let client = context.channel
        let env = self.env

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
                    handlers.append(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)))
                    handlers.append(UpstreamResponseHandler(client: client, flow: flow, environment: env))
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

    static func isWebSocketUpgrade(_ request: HTTPRequestRecord) -> Bool {
        request.headers.contains { $0.name.caseInsensitiveCompare("Upgrade") == .orderedSame && $0.value.lowercased() == "websocket" }
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
/// When a response breakpoint matches, the whole response is held until the user releases it.
final class UpstreamResponseHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let client: Channel
    private var flow: Flow
    private let store: FlowStore
    private let pauseHandler: BreakpointHandler?
    private let rules: TrafficRules
    /// The response is buffered (not streamed) when a breakpoint or a script needs the whole message.
    private let holds: Bool
    private var response: HTTPResponseRecord?
    private var body = Data()
    private var upgrading = false

    init(client: Channel, flow: Flow, environment: ProxyEnvironment) {
        self.client = client
        self.flow = flow
        self.store = environment.store
        self.pauseHandler = environment.rules.breakpointHandler(request: flow.request, phase: .response)
        self.rules = environment.rules
        self.holds = pauseHandler != nil || environment.rules.hasScripts(for: flow.request)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            response = HTTPResponseRecord(
                status: Int(h.status.code), reason: h.status.reasonPhrase,
                headers: h.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
            )
            if h.status.code == 101, ProxyFrontendHandler.isWebSocketUpgrade(flow.request) {
                upgrading = true
                context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
                return
            }
            guard !holds else { return }
            var headers = h.headers
            headers.replaceOrAdd(name: "Connection", value: "close")
            client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: h.status, headers: headers)), promise: nil)
        case .body(let buf):
            if upgrading { return }
            body.append(contentsOf: buf.readableBytesView)
            if !holds { client.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil) }
        case .end:
            if upgrading, let response {
                flow.response = response
                flow.duration = Date().timeIntervalSince(flow.startedAt)
                WebSocketBridge.start(upstream: context, client: client, response: response, flow: flow, store: store)
                return
            }
            response?.body = body
            if holds, var held = response {
                let scripted = rules.applyScripts(to: held, for: flow.request)
                held = scripted.value
                flow.notes += scripted.notes
                if let pauseHandler {
                    let request = flow.request, client = self.client, held = held
                    Task {
                        let edited = await pauseHandler.resume(response: held, for: request)
                        client.eventLoop.execute { self.deliver(edited) }
                    }
                } else {
                    deliver(held)
                }
            } else {
                record(response)
                client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [client] _ in client.close(promise: nil) }
            }
            context.close(promise: nil)
        }
    }

    /// Writes a held (possibly edited) response; nil means the user cancelled it.
    private func deliver(_ edited: HTTPResponseRecord?) {
        record(edited ?? HTTPResponseRecord(status: 499, reason: "Cancelled by Proxio"))
        ResponseWriter.write(edited, to: client)
    }

    private func record(_ response: HTTPResponseRecord?) {
        flow.response = response
        flow.duration = Date().timeIntervalSince(flow.startedAt)
        let done = flow, store = self.store
        Task { await store.add(done) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        client.close(promise: nil)
        context.close(promise: nil)
    }
}

/// Writes a complete, already-buffered response and closes the connection.
enum ResponseWriter {
    static func write(_ response: HTTPResponseRecord?, to client: Channel) {
        guard let response else {
            let headers = HTTPHeaders([("Content-Length", "0"), ("Connection", "close")])
            client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .custom(code: 499, reasonPhrase: "Cancelled by Proxio"), headers: headers)), promise: nil)
            client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [client] _ in client.close(promise: nil) }
            return
        }
        var headers = HTTPHeaders()
        for h in response.headers { headers.add(name: h.name, value: h.value) }
        for name in ["Transfer-Encoding", "Content-Length", "Connection"] { headers.remove(name: name) }
        headers.add(name: "Content-Length", value: String(response.body.count))
        headers.add(name: "Connection", value: "close")
        let status = HTTPResponseStatus(statusCode: response.status, reasonPhrase: response.reason)
        client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)), promise: nil)
        if !response.body.isEmpty { client.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: response.body))), promise: nil) }
        client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [client] _ in client.close(promise: nil) }
    }
}
