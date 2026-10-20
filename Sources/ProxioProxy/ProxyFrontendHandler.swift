import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOTLS
import NIOHTTP2
import ProxioCore

struct ProxyEnvironment {
    let store: FlowStore
    let ca: CertificateAuthority?
    let sslProxying: SSLProxyingPolicy
    let upstreamSSLContext: NIOSSLContext
    /// Same trust settings as `upstreamSSLContext`, but also offers `h2` through ALPN.
    let upstreamH2SSLContext: NIOSSLContext
    let pool = UpstreamPool()
    let rules: TrafficRules
    let conditions: NetworkConditions

    /// The 403 answer for a request the Block / Allow lists refuse, with the reason noted on the flow.
    func blockedResponse(_ reason: String) -> HTTPResponseRecord {
        HTTPResponseRecord(status: 403, reason: "Forbidden",
                           headers: [HTTPHeader(name: "Content-Type", value: "text/plain; charset=utf-8")],
                           body: Data("\(reason) by Proxio".utf8))
    }

    /// Starts a flow for `request` and applies Map Local / Map Remote and scripts.
    func prepare(_ request: HTTPRequestRecord, startedAt: Date) -> (flow: Flow, local: MapLocalRule?) {
        var flow = Flow(startedAt: startedAt, request: request)
        let local = rules.mapLocal(for: request)
        if local != nil {
            flow.notes.append("Map Local")
        } else if let (rule, rewritten) = rules.mapRemote(for: request) {
            flow.request.url = rewritten
            flow.notes.append(rule.summary)
        }
        let scripted = rules.applyScripts(to: flow.request)
        flow.request = scripted.value
        flow.notes += scripted.notes
        return (flow, local)
    }
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
    /// Whether the client allows this connection to carry another request after the response.
    private var keepAlive = false

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
            keepAlive = h.isKeepAlive && h.method != .CONNECT
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
        let bypassed = env.rules.isBypassed(host: host, port: port)
        if !bypassed, let ca = env.ca, env.sslProxying.rules.shouldIntercept(host: host, port: port),
           let sslContext = try? ca.serverContext(for: host) {
            return intercept(context: context, host: host, port: port, sslContext: sslContext)
        }
        if !bypassed, let reason = env.rules.blockReason(forTunnelTo: host, port: port) {
            let record = Flow(
                startedAt: startedAt,
                request: HTTPRequestRecord(method: "CONNECT", url: URL(string: "https://\(host):\(port)")!),
                response: env.blockedResponse(reason), notes: [reason]
            )
            let store = env.store
            Task { await store.add(record) }
            return fail(context: context, status: .forbidden)
        }
        let client = context.channel
        let store = env.store
        let started = startedAt
        let bypass = bypassed
        ClientBootstrap(group: context.eventLoop)
            .connect(host: env.rules.dnsOverride(for: host) ?? host, port: port)
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
                    if !bypass { Task { await store.add(record) } }

                    // A 2xx CONNECT reply has no body framing, so it is written raw,
                    // after the HTTP codec is gone and the relays are in place.
                    let pipeline = client.pipeline
                    _ = pipeline.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self).flatMap { pipeline.removeHandler($0) }
                        .flatMap { _ in pipeline.handler(type: HTTPResponseEncoder.self) }.flatMap { pipeline.removeHandler($0) }
                        .flatMap { _ in pipeline.handler(type: HTTPServerPipelineHandler.self) }.flatMap { pipeline.removeHandler($0) }
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
            .flatMap { _ in pipeline.handler(type: HTTPServerPipelineHandler.self) }.flatMap { pipeline.removeHandler($0) }
            .flatMap { _ -> EventLoopFuture<Void> in
                // Same event-loop turn: the reply goes out in clear, the TLS layer is installed before any ClientHello can be read.
                client.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n"), promise: nil)
                // The forged certificate offers h2 and http/1.1; whichever the client picks decides the codec.
                let alpn = ApplicationProtocolNegotiationHandler { result, channel in
                    if case .negotiated(let name) = result, name == "h2" {
                        return channel.configureHTTP2Pipeline(mode: .server) { stream in
                            stream.pipeline.addHandler(HTTP2StreamHandler(environment: env, tunnel: (host, port)))
                        }.map { _ in }
                    }
                    return channel.pipeline.addHandlers([
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)),
                        HTTPResponseEncoder(),
                        HTTPServerPipelineHandler(),
                        ProxyFrontendHandler(environment: env, tunnel: (host, port)),
                    ])
                }
                return pipeline.addHandlers([NIOSSLServerHandler(context: sslContext), alpn], position: .before(self))
            }
            .flatMap { pipeline.removeHandler(self) }
            .whenFailure { _ in client.close(promise: nil) }
    }

    // MARK: Forwarding (plain HTTP, or decrypted HTTPS inside a tunnel)

    /// Builds the request record, lets breakpoints edit it, then sends it upstream.
    private func forward(context: ChannelHandlerContext, head: HTTPRequestHead) {
        if SetupSite.isSetupRequest(uri: head.uri, tunnel: tunnel != nil) {
            // Addressed to the proxy itself: answer with the setup site and keep it out of the captured traffic.
            return ResponseWriter.write(SetupSite.respond(path: head.uri, ca: env.ca), to: context.channel, keepAlive: keepAlive)
        }
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
        var (flow, local) = env.prepare(request, startedAt: startedAt)
        if let reason = env.rules.blockReason(for: flow.request) {
            flow.notes.append(reason)
            return Self.finish(flow, with: env.blockedResponse(reason), client: context.channel, store: env.store, keepAlive: keepAlive)
        }

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
        let client = context.channel, env = self.env, keepAlive = self.keepAlive
        guard let handler = env.rules.breakpointHandler(request: flow.request, phase: .response) else {
            return Self.finish(flow, with: response, client: client, store: env.store, keepAlive: keepAlive)
        }
        Task {
            let edited = await handler.resume(response: response, for: flow.request)
            client.eventLoop.execute { Self.finish(flow, with: edited, client: client, store: env.store, keepAlive: keepAlive) }
        }
    }

    /// Records the exchange and writes `response` (nil = cancelled at a breakpoint).
    static func finish(_ flow: Flow, with response: HTTPResponseRecord?, client: Channel, store: FlowStore, keepAlive: Bool) {
        var flow = flow
        flow.response = response ?? HTTPResponseRecord(status: 499, reason: "Cancelled by Proxio")
        flow.duration = Date().timeIntervalSince(flow.startedAt)
        let done = flow
        Task { await store.add(done) }
        ResponseWriter.write(response, to: client, keepAlive: keepAlive)
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
        if !Self.isWebSocketUpgrade(request) {
            // Pooled path: reuses idle origin connections, and shares one HTTP/2 connection when the origin offers it.
            let sameOrigin = original.url.host == url.host && original.url.port == url.port
            let clientHost = request.headers.first { $0.name.caseInsensitiveCompare("Host") == .orderedSame }?.value
            let exchange = HTTP1Exchange(client: context.channel, flow: flow, environment: env, keepAlive: keepAlive)
            return UpstreamConnection.open(request: request, env: env, loop: context.eventLoop, hostHeader: sameOrigin ? clientHost : nil, delegate: exchange)
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
        let keepAlive = self.keepAlive

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
                    handlers.append(UpstreamResponseHandler(client: client, flow: flow, environment: env, keepAlive: keepAlive))
                    try ch.pipeline.syncOperations.addHandlers(handlers)
                    return ch.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: env.rules.dnsOverride(for: host) ?? host, port: port)
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
    /// The client wants to reuse its connection; downgraded to false when the response has no length framing.
    private var keepAlive: Bool
    private var timing = TimingTracker()

    init(client: Channel, flow: Flow, environment: ProxyEnvironment, keepAlive: Bool) {
        self.keepAlive = keepAlive
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
            headers.remove(name: "Connection")
            keepAlive = keepAlive && Self.isFramed(h, method: flow.request.method)
            headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
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
                let reuse = keepAlive
                client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [client] _ in if !reuse { client.close(promise: nil) } }
            }
            context.close(promise: nil)
        }
    }

    /// Writes a held (possibly edited) response; nil means the user cancelled it.
    private func deliver(_ edited: HTTPResponseRecord?) {
        record(edited ?? HTTPResponseRecord(status: 499, reason: "Cancelled by Proxio"))
        ResponseWriter.write(edited, to: client, keepAlive: keepAlive)
    }

    /// Whether the client can tell where the body ends without the connection closing.
    private static func isFramed(_ head: HTTPResponseHead, method: String) -> Bool {
        if method.uppercased() == "HEAD" || head.status.code < 200 || head.status.code == 204 || head.status.code == 304 { return true }
        if head.headers.contains(name: "Content-Length") { return true }
        return head.headers[canonicalForm: "Transfer-Encoding"].contains { $0.lowercased() == "chunked" }
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

/// Answers an HTTP/1.1 client from a pooled upstream connection (HTTP/1.1 or HTTP/2 origin), streaming the
/// response through and recording a copy. A response breakpoint or script holds the whole message instead.
final class HTTP1Exchange: UpstreamDelegate {
    private let client: Channel
    private var flow: Flow
    private let store: FlowStore
    private let pauseHandler: BreakpointHandler?
    private let rules: TrafficRules
    private let holds: Bool
    private var response: HTTPResponseRecord?
    private var body = Data()
    private var wroteHead = false
    /// The client wants to reuse its connection; downgraded when the response has no length framing.
    private var keepAlive: Bool
    private var timing = TimingTracker()

    init(client: Channel, flow: Flow, environment: ProxyEnvironment, keepAlive: Bool) {
        self.client = client
        self.flow = flow
        self.keepAlive = keepAlive
        self.store = environment.store
        self.rules = environment.rules
        self.pauseHandler = environment.rules.breakpointHandler(request: flow.request, phase: .response)
        self.holds = pauseHandler != nil || environment.rules.hasScripts(for: flow.request)
    }

    func upstreamStarted() { timing.start() }
    func upstreamConnected(after seconds: TimeInterval) { timing.connected(seconds) }

    func upstreamHead(status: Int, reason: String, headers: [HTTPHeader]) {
        timing.head()
        response = HTTPResponseRecord(status: status, reason: reason, headers: headers)
        guard !holds else { return }
        var out = HTTPHeaders()
        for h in headers where !["connection", "keep-alive", "proxy-connection", "upgrade"].contains(h.name.lowercased()) { out.add(name: h.name, value: h.value) }
        keepAlive = keepAlive && Self.isFramed(status: status, headers: headers, method: flow.request.method)
        out.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        wroteHead = true
        client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status, reasonPhrase: reason), headers: out)), promise: nil)
    }

    func upstreamBody(_ bytes: ByteBuffer) {
        body.append(contentsOf: bytes.readableBytesView)
        if !holds { client.write(HTTPServerResponsePart.body(.byteBuffer(bytes)), promise: nil) }
    }

    func upstreamEnd(trailers: [HTTPHeader]) {
        guard var held = response else { return upstreamFailed(UpstreamError.closed) }
        held.body = body
        held.trailers = trailers
        guard holds else {
            record(held)
            let reuse = keepAlive
            client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [client] _ in if !reuse { client.close(promise: nil) } }
            return
        }
        let scripted = rules.applyScripts(to: held, for: flow.request)
        held = scripted.value
        flow.notes += scripted.notes
        guard let pauseHandler else { return deliver(held) }
        let request = flow.request, snapshot = held
        Task {
            let edited = await pauseHandler.resume(response: snapshot, for: request)
            self.client.eventLoop.execute { self.deliver(edited) }
        }
    }

    func upstreamFailed(_ error: Error) {
        if wroteHead { return client.close(promise: nil) }
        let headers = HTTPHeaders([("Content-Length", "0"), ("Connection", "close")])
        client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)), promise: nil)
        client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [client] _ in client.close(promise: nil) }
    }

    private func deliver(_ edited: HTTPResponseRecord?) {
        record(edited ?? HTTPResponseRecord(status: 499, reason: "Cancelled by Proxio"))
        ResponseWriter.write(edited, to: client, keepAlive: keepAlive)
    }

    private func record(_ response: HTTPResponseRecord) {
        flow.response = response
        flow.duration = Date().timeIntervalSince(flow.startedAt)
        flow.timings = timing.result()
        let done = flow, store = self.store
        Task { await store.add(done) }
    }

    /// Whether the client can tell where the body ends without the connection closing.
    private static func isFramed(status: Int, headers: [HTTPHeader], method: String) -> Bool {
        if method.uppercased() == "HEAD" || status < 200 || status == 204 || status == 304 { return true }
        return headers.contains { h in
            let n = h.name.lowercased()
            return n == "content-length" || (n == "transfer-encoding" && h.value.lowercased().contains("chunked"))
        }
    }
}

/// Writes a complete, already-buffered response, then closes the connection unless it is kept alive.
enum ResponseWriter {
    static func write(_ response: HTTPResponseRecord?, to client: Channel, keepAlive: Bool) {
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
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        let status = HTTPResponseStatus(statusCode: response.status, reasonPhrase: response.reason)
        client.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)), promise: nil)
        if !response.body.isEmpty { client.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: response.body))), promise: nil) }
        client.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { [client] _ in if !keepAlive { client.close(promise: nil) } }
    }
}
