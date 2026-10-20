import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHPACK
import NIOHTTP2
import NIOSSL
import NIOTLS
import ProxioCore

// HTTP/2 support. The client side only exists inside intercepted tunnels (ALPN `h2` on the
// forged certificate); the upstream side negotiates `h2` or `http/1.1` with the origin.
// Upstream connections are pooled: idle HTTP/1.1 connections are reused and HTTP/2 origins get one connection with a stream per request.

/// Callbacks from an upstream connection, always on the event loop it was opened on.
protocol UpstreamDelegate: AnyObject {
    func upstreamHead(status: Int, reason: String, headers: [HTTPHeader])
    func upstreamBody(_ bytes: ByteBuffer)
    func upstreamEnd(trailers: [HTTPHeader])
    func upstreamFailed(_ error: Error)
    /// The request is about to be sent upstream (pooled or not).
    func upstreamStarted()
    /// A new upstream connection (TCP and TLS) is ready after `seconds`.
    func upstreamConnected(after seconds: TimeInterval)
}

extension UpstreamDelegate {
    func upstreamStarted() {}
    func upstreamConnected(after seconds: TimeInterval) {}
}

/// Measures connect / wait / receive for one upstream exchange.
struct TimingTracker {
    private var started = Date()
    private var connect: TimeInterval?
    private var headAt: Date?

    mutating func start() { started = Date(); connect = nil; headAt = nil }
    mutating func connected(_ seconds: TimeInterval) { connect = seconds }
    mutating func head() { if headAt == nil { headAt = Date() } }
    func result() -> FlowTimings? {
        guard let headAt else { return nil }
        return FlowTimings(connect: connect, wait: max(0, headAt.timeIntervalSince(started) - (connect ?? 0)), receive: max(0, Date().timeIntervalSince(headAt)))
    }
}

enum UpstreamError: Error { case badRequest, closed }

/// Headers that describe one HTTP/1.1 connection and must not cross into HTTP/2 (RFC 9113 §8.2.2).
private let connectionSpecific: Set<String> = ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "host"]

private func isPseudo(_ name: String) -> Bool { name.hasPrefix(":") }

/// Idle HTTP/1.1 connections and live HTTP/2 connections to origins, so repeated requests skip the TCP and TLS handshakes.
/// Entries are per event loop: a channel is only ever touched from the loop it was created on.
final class UpstreamPool: @unchecked Sendable {
    struct Key: Hashable {
        let host: String, port: Int, tls: Bool, loop: ObjectIdentifier
    }

    final class H2Connection {
        let channel: Channel
        let multiplexer: HTTP2StreamMultiplexer
        var active = 0
        var idleToken = 0
        init(channel: Channel, multiplexer: HTTP2StreamMultiplexer) { self.channel = channel; self.multiplexer = multiplexer }
    }

    static let idleLifetime: TimeAmount = .seconds(30)
    static let maxIdlePerHost = 8

    private let lock = NSLock()
    private var idle: [Key: [PooledHTTP1Handler]] = [:]
    private var h2: [Key: H2Connection] = [:]

    /// An idle HTTP/1.1 connection that is still open, most recently used first.
    func takeIdle(_ key: Key) -> PooledHTTP1Handler? {
        lock.withLock {
            while var list = idle[key], let handler = list.popLast() {
                idle[key] = list
                if handler.isUsable { return handler }
            }
            return nil
        }
    }

    func release(_ key: Key, _ handler: PooledHTTP1Handler) {
        let kept = lock.withLock { () -> Bool in
            var list = idle[key] ?? []
            guard list.count < Self.maxIdlePerHost else { return false }
            list.append(handler)
            idle[key] = list
            return true
        }
        if !kept { handler.channel?.close(promise: nil) }
    }

    func remove(_ key: Key, _ handler: PooledHTTP1Handler) {
        lock.withLock { idle[key]?.removeAll { $0 === handler } }
    }

    func liveH2(_ key: Key) -> H2Connection? {
        lock.withLock { h2[key].flatMap { $0.channel.isActive ? $0 : nil } }
    }

    func register(_ key: Key, _ connection: H2Connection) {
        lock.withLock { h2[key] = connection }
        connection.channel.closeFuture.whenComplete { [weak self, weak connection] _ in
            guard let self, let connection else { return }
            self.lock.withLock { if self.h2[key] === connection { self.h2[key] = nil } }
        }
    }

    /// Closes everything idle (used when the proxy stops).
    func closeAll() {
        let (handlers, conns) = lock.withLock { () -> ([PooledHTTP1Handler], [H2Connection]) in
            defer { idle = [:]; h2 = [:] }
            return (idle.values.flatMap { $0 }, Array(h2.values))
        }
        handlers.forEach { $0.channel?.close(promise: nil) }
        conns.forEach { $0.channel.close(promise: nil) }
    }
}

enum UpstreamConnection {
    private enum Conn {
        case h1(PooledHTTP1Handler, reused: Bool)
        case h2(UpstreamPool.H2Connection, reused: Bool)
    }

    /// Sends `request` to the origin it names and reports the answer to `delegate`.
    /// A reused connection that turns out to be dead before any response byte is retried once on a fresh one.
    static func open(request: HTTPRequestRecord, env: ProxyEnvironment, loop: EventLoop, hostHeader: String? = nil, delegate inner: UpstreamDelegate) {
        let delegate = NoHTTP3(inner)
        let url = request.url
        guard let host = url.host, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return delegate.upstreamFailed(UpstreamError.badRequest)
        }
        delegate.upstreamStarted()
        let useTLS = scheme == "https"
        let port = url.port ?? (useTLS ? 443 : 80)
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let q = components.percentEncodedQuery { path += "?\(q)" }
        let authority = url.port.map { "\(host):\($0)" } ?? host
        var request = request
        if env.rules.breakpointHandler(request: request, phase: .response) != nil || env.rules.hasScripts(for: request) {
            // A held body must be readable and editable.
            request.headers.removeAll { $0.name.caseInsensitiveCompare("Accept-Encoding") == .orderedSame }
            request.headers.append(HTTPHeader(name: "Accept-Encoding", value: "identity"))
        }
        let target = Target(request: request, host: host, port: port, tls: useTLS, path: path, authority: hostHeader ?? authority,
                            connectHost: env.rules.dnsOverride(for: host) ?? host, key: .init(host: host, port: port, tls: useTLS, loop: ObjectIdentifier(loop)))
        attempt(target, env: env, loop: loop, delegate: delegate, allowReuse: true)
    }

    private struct Target {
        let request: HTTPRequestRecord
        let host: String, port: Int, tls: Bool, path: String, authority: String, connectHost: String
        let key: UpstreamPool.Key
        /// HEAD answers carry a Content-Length with no body, which the HTTP/1 decoder cannot tell; those never reuse.
        var poolable: Bool { request.method.uppercased() != "HEAD" }
    }

    private static func attempt(_ t: Target, env: ProxyEnvironment, loop: EventLoop, delegate: UpstreamDelegate, allowReuse: Bool) {
        if allowReuse, t.poolable {
            if let conn = env.pool.liveH2(t.key) {
                return sendHTTP2(t, on: conn, env: env, delegate: Retrying(delegate) { attempt(t, env: env, loop: loop, delegate: delegate, allowReuse: false) })
            }
            if let handler = env.pool.takeIdle(t.key) {
                return sendHTTP1(t, on: handler, reused: true, env: env,
                                 delegate: Retrying(delegate) { attempt(t, env: env, loop: loop, delegate: delegate, allowReuse: false) })
            }
        }
        connect(t, env: env, loop: loop, delegate: delegate)
    }

    private static func connect(_ t: Target, env: ProxyEnvironment, loop: EventLoop, delegate: UpstreamDelegate) {
        let began = Date()
        UpstreamDialer.dial(host: t.connectHost, port: t.port, via: env.rules.externalProxy(for: t.host), loop: loop)
            .whenComplete { result in
                switch result {
                case .failure(let error): delegate.upstreamFailed(error)
                case .success(let channel):
                    if t.tls {
                        do {
                            let ssl = try NIOSSLClientHandler(
                                context: env.upstreamH2SSLContext,
                                serverHostname: ProxyFrontendHandler.isIPAddress(t.host) ? nil : t.host
                            )
                            let alpn = ApplicationProtocolNegotiationHandler { result, channel in
                                if case .negotiated(let protocolName) = result, protocolName == "h2" {
                                    return channel.configureHTTP2Pipeline(mode: .client, inboundStreamInitializer: nil).map { multiplexer in
                                        let conn = UpstreamPool.H2Connection(channel: channel, multiplexer: multiplexer)
                                        env.pool.register(t.key, conn)
                                        delegate.upstreamConnected(after: Date().timeIntervalSince(began))
                                        sendHTTP2(t, on: conn, env: env, delegate: delegate)
                                    }
                                }
                                return installHTTP1(on: channel).map { handler in
                                    delegate.upstreamConnected(after: Date().timeIntervalSince(began))
                                    sendHTTP1(t, on: handler, reused: false, env: env, delegate: delegate)
                                }
                            }
                            try channel.pipeline.syncOperations.addHandlers([ssl, alpn])
                        } catch {
                            channel.close(promise: nil)
                            delegate.upstreamFailed(error)
                        }
                    } else {
                        installHTTP1(on: channel).whenComplete {
                            switch $0 {
                            case .success(let handler):
                                delegate.upstreamConnected(after: Date().timeIntervalSince(began))
                                sendHTTP1(t, on: handler, reused: false, env: env, delegate: delegate)
                            case .failure(let error): delegate.upstreamFailed(error)
                            }
                        }
                    }
                }
            }
    }

    // MARK: HTTP/1.1

    private static func installHTTP1(on channel: Channel) -> EventLoopFuture<PooledHTTP1Handler> {
        channel.eventLoop.makeCompletedFuture {
            let handler = PooledHTTP1Handler()
            try channel.pipeline.syncOperations.addHandlers([
                HTTPRequestEncoder(),
                ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                handler,
            ])
            return handler
        }
    }

    private static func sendHTTP1(_ t: Target, on handler: PooledHTTP1Handler, reused: Bool, env: ProxyEnvironment, delegate: UpstreamDelegate) {
        guard let channel = handler.channel else { return delegate.upstreamFailed(UpstreamError.closed) }
        let request = t.request
        var headers = HTTPHeaders()
        for h in request.headers where !isPseudo(h.name) { headers.add(name: h.name, value: h.value) }
        for name in ["Proxy-Connection", "Transfer-Encoding", "Content-Length", "Connection", "Keep-Alive", "Upgrade", "TE", "Host"] { headers.remove(name: name) }
        headers.add(name: "Host", value: t.authority)
        if !t.poolable { headers.add(name: "Connection", value: "close") }
        if !request.body.isEmpty || ["POST", "PUT", "PATCH"].contains(request.method.uppercased()) {
            headers.add(name: "Content-Length", value: String(request.body.count))
        }
        let head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method), uri: t.path, headers: headers)
        let body = request.body
        let key = t.key, pool = env.pool
        handler.begin(delegate: delegate, mayReuse: t.poolable) { [weak handler] in
            guard let handler else { return }
            pool.release(key, handler)
        } onDead: { [weak handler] in
            guard let handler else { return }
            pool.remove(key, handler)
        }
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        if !body.isEmpty { channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil) }
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
    }

    // MARK: HTTP/2

    private static func sendHTTP2(_ t: Target, on conn: UpstreamPool.H2Connection, env: ProxyEnvironment, delegate: UpstreamDelegate) {
        let request = t.request
        var fields: [(String, String)] = [
            (":method", request.method), (":scheme", request.url.scheme ?? "https"),
            (":authority", t.authority), (":path", t.path),
        ]
        for h in request.headers where !isPseudo(h.name) {
            let name = h.name.lowercased()
            if connectionSpecific.contains(name) || name == "content-length" { continue }
            if name == "te", h.value.lowercased() != "trailers" { continue }
            fields.append((name, h.value))
        }
        if !request.body.isEmpty { fields.append(("content-length", String(request.body.count))) }
        let headers = HPACKHeaders(fields)
        let body = request.body
        let loop = conn.channel.eventLoop

        conn.active += 1
        conn.idleToken += 1
        let streamReady = loop.makePromise(of: Channel.self)
        conn.multiplexer.createStreamChannel(promise: streamReady) { stream in
            stream.pipeline.addHandler(HTTP2UpstreamHandler(delegate: delegate))
        }
        streamReady.futureResult.whenComplete { result in
            switch result {
            case .failure(let error):
                conn.active -= 1
                delegate.upstreamFailed(error)
            case .success(let stream):
                stream.closeFuture.whenComplete { _ in
                    conn.active -= 1
                    guard conn.active == 0 else { return }
                    let token = conn.idleToken
                    loop.scheduleTask(in: .seconds(60)) {
                        if conn.active == 0, conn.idleToken == token { conn.channel.close(promise: nil) }
                    }
                }
                stream.write(HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: body.isEmpty)), promise: nil)
                if !body.isEmpty {
                    stream.write(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(bytes: body)), endStream: true)), promise: nil)
                }
                stream.flush()
            }
        }
    }

    /// Hides `Alt-Svc` HTTP/3 offers from the client; QUIC would bypass the proxy.
    private final class NoHTTP3: UpstreamDelegate {
        private let inner: UpstreamDelegate
        init(_ inner: UpstreamDelegate) { self.inner = inner }
        func upstreamHead(status: Int, reason: String, headers: [HTTPHeader]) { inner.upstreamHead(status: status, reason: reason, headers: AltSvc.removingHTTP3(from: headers)) }
        func upstreamBody(_ bytes: ByteBuffer) { inner.upstreamBody(bytes) }
        func upstreamEnd(trailers: [HTTPHeader]) { inner.upstreamEnd(trailers: trailers) }
        func upstreamFailed(_ error: Error) { inner.upstreamFailed(error) }
        func upstreamStarted() { inner.upstreamStarted() }
        func upstreamConnected(after seconds: TimeInterval) { inner.upstreamConnected(after: seconds) }
    }

    /// Passes everything through; if the connection dies before the response starts, runs `retry` instead of failing.
    private final class Retrying: UpstreamDelegate {
        private let inner: UpstreamDelegate
        private var retry: (() -> Void)?
        private var sawHead = false
        init(_ inner: UpstreamDelegate, retry: @escaping () -> Void) { self.inner = inner; self.retry = retry }
        func upstreamHead(status: Int, reason: String, headers: [HTTPHeader]) { sawHead = true; inner.upstreamHead(status: status, reason: reason, headers: headers) }
        func upstreamBody(_ bytes: ByteBuffer) { inner.upstreamBody(bytes) }
        func upstreamStarted() { inner.upstreamStarted() }
        func upstreamConnected(after seconds: TimeInterval) { inner.upstreamConnected(after: seconds) }
        func upstreamEnd(trailers: [HTTPHeader]) { inner.upstreamEnd(trailers: trailers) }
        func upstreamFailed(_ error: Error) {
            if !sawHead, let retry { self.retry = nil; return retry() }
            inner.upstreamFailed(error)
        }
    }
}

/// One HTTP/1.1 origin connection that can carry several requests in turn. Idle between them.
final class PooledHTTP1Handler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private(set) var channel: Channel?
    private var delegate: UpstreamDelegate?
    private var onIdle: (() -> Void)?
    private var onDead: (() -> Void)?
    private var mayReuse = false
    private var keepAlive = false
    private var ignoringInformational = false
    private var idleToken = 0

    var isUsable: Bool { channel?.isActive == true && delegate == nil }

    func handlerAdded(context: ChannelHandlerContext) { channel = context.channel }

    func begin(delegate: UpstreamDelegate, mayReuse: Bool, onIdle: @escaping () -> Void, onDead: @escaping () -> Void) {
        idleToken += 1
        self.delegate = delegate
        self.mayReuse = mayReuse
        self.onIdle = onIdle
        self.onDead = onDead
        keepAlive = false
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard delegate != nil else { return context.close(promise: nil) }   // bytes nobody asked for
        switch unwrapInboundIn(data) {
        case .head(let h):
            if h.status.code < 200 && h.status.code != 101 { ignoringInformational = true; return }
            keepAlive = mayReuse && h.version == .http1_1 && !(h.headers[canonicalForm: "connection"].contains { $0.lowercased() == "close" })
            delegate?.upstreamHead(
                status: Int(h.status.code), reason: h.status.reasonPhrase,
                headers: h.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
            )
        case .body(let buf):
            if !ignoringInformational { delegate?.upstreamBody(buf) }
        case .end(let trailers):
            if ignoringInformational { ignoringInformational = false; return }
            let d = delegate
            delegate = nil
            let release = onIdle
            onIdle = nil
            onDead = nil
            d?.upstreamEnd(trailers: trailers?.map { HTTPHeader(name: $0.name, value: $0.value) } ?? [])
            if keepAlive, context.channel.isActive {
                idleToken += 1
                let token = idleToken
                context.eventLoop.scheduleTask(in: UpstreamPool.idleLifetime) { [weak self] in
                    if let self, self.delegate == nil, self.idleToken == token { self.onDead?(); context.close(promise: nil) }
                }
                release?()
            } else {
                context.close(promise: nil)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) { fail(UpstreamError.closed) }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }
    private func fail(_ error: Error) {
        let d = delegate
        delegate = nil
        onDead?()
        onDead = nil
        onIdle = nil
        d?.upstreamFailed(error)
    }
}

/// Reads one HTTP/2 response stream from an origin. The connection stays open for other streams.
private final class HTTP2UpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    private var delegate: UpstreamDelegate?
    private var sawHead = false
    init(delegate: UpstreamDelegate) { self.delegate = delegate }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .headers(let h):
            let fields = h.headers.filter { !isPseudo($0.name) }.map { HTTPHeader(name: $0.name, value: $0.value) }
            if !sawHead {
                let status = h.headers[":status"].first.flatMap(Int.init) ?? 502
                if status < 200 { return }   // informational (100 Continue, 103 Early Hints)
                sawHead = true
                delegate?.upstreamHead(status: status, reason: HTTPResponseStatus(statusCode: status).reasonPhrase, headers: fields)
                if h.endStream { finish(context, trailers: []) }
            } else {
                finish(context, trailers: fields)
            }
        case .data(let d):
            if case .byteBuffer(let buf) = d.data { delegate?.upstreamBody(buf) }
            if d.endStream { finish(context, trailers: []) }
        case .rstStream: fail(context, UpstreamError.closed)
        default: break
        }
    }

    private func finish(_ context: ChannelHandlerContext, trailers: [HTTPHeader]) {
        let d = delegate
        delegate = nil
        d?.upstreamEnd(trailers: trailers)
        context.close(promise: nil)
    }
    private func fail(_ context: ChannelHandlerContext, _ error: Error) {
        let d = delegate
        delegate = nil
        d?.upstreamFailed(error)
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) { fail(context, UpstreamError.closed) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(context, error) }
}

/// One client-initiated HTTP/2 stream in an intercepted tunnel: collects the request, runs it
/// through the rules and answers on the same stream.
final class HTTP2StreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let env: ProxyEnvironment
    private let tunnel: (host: String, port: Int)
    private var headers: HPACKHeaders?
    private var body = Data()
    private var startedAt = Date()
    private var dispatched = false

    init(environment: ProxyEnvironment, tunnel: (host: String, port: Int)) {
        self.env = environment
        self.tunnel = tunnel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .headers(let h):
            if headers == nil {
                headers = h.headers
                startedAt = Date()
            }
            if h.endStream { dispatch(context) }
        case .data(let d):
            if case .byteBuffer(let buf) = d.data { body.append(contentsOf: buf.readableBytesView) }
            if d.endStream { dispatch(context) }
        default: break
        }
    }

    private func dispatch(_ context: ChannelHandlerContext) {
        guard !dispatched, let headers else { return }
        dispatched = true
        let authority = tunnel.port == 443 ? tunnel.host : "\(tunnel.host):\(tunnel.port)"
        let path = headers[":path"].first ?? "/"
        guard let url = URL(string: "https://\(authority)\(path)") else {
            return HTTP2Exchange.reply(status: 400, on: context.channel)
        }
        var fields = headers.filter { !isPseudo($0.name) }.map { HTTPHeader(name: $0.name, value: $0.value) }
        fields.insert(HTTPHeader(name: "Host", value: headers[":authority"].first ?? authority), at: 0)
        let request = HTTPRequestRecord(method: headers[":method"].first ?? "GET", url: url, httpVersion: "HTTP/2", headers: fields, body: body)
        HTTP2Exchange(environment: env, stream: context.channel, startedAt: startedAt).start(request)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Runs one HTTP/2 request through breakpoints, Map Local/Remote and scripts, then answers the
/// stream. The response streams through unless a breakpoint or script needs the whole message.
final class HTTP2Exchange: UpstreamDelegate {
    private let env: ProxyEnvironment
    private let stream: Channel
    private let startedAt: Date
    private var flow: Flow
    private var response: HTTPResponseRecord?
    private var body = Data()
    private var holds = false
    private var streamed = false
    private var pause: BreakpointHandler?
    private var timing = TimingTracker()

    init(environment: ProxyEnvironment, stream: Channel, startedAt: Date) {
        self.env = environment
        self.stream = stream
        self.startedAt = startedAt
        self.flow = Flow(startedAt: startedAt, request: HTTPRequestRecord(method: "", url: URL(string: "about:blank")!))
    }

    func start(_ request: HTTPRequestRecord) {
        let (prepared, local) = env.prepare(request, startedAt: startedAt)
        flow = prepared
        if let reason = env.rules.blockReason(for: flow.request) {
            flow.notes.append(reason)
            return finish(env.blockedResponse(reason))
        }
        guard let handler = env.rules.breakpointHandler(request: flow.request, phase: .request) else {
            return proceed(local: local)
        }
        let loop = stream.eventLoop, paused = flow
        Task {
            let edited = await handler.resume(request: paused.request)
            loop.execute {
                guard let edited else { return self.finish(HTTPResponseRecord(status: 499, reason: "Cancelled by Proxio")) }
                self.flow.request = edited
                self.proceed(local: local)
            }
        }
    }

    private func proceed(local: MapLocalRule?) {
        pause = env.rules.breakpointHandler(request: flow.request, phase: .response)
        holds = pause != nil || env.rules.hasScripts(for: flow.request)
        if let local {
            let scripted = env.rules.applyScripts(to: local.makeResponse(), for: flow.request)
            flow.notes += scripted.notes
            return conclude(scripted.value)
        }
        UpstreamConnection.open(request: flow.request, env: env, loop: stream.eventLoop, delegate: self)
    }

    // MARK: UpstreamDelegate

    func upstreamStarted() { timing.start() }
    func upstreamConnected(after seconds: TimeInterval) { timing.connected(seconds) }

    func upstreamHead(status: Int, reason: String, headers: [HTTPHeader]) {
        timing.head()
        response = HTTPResponseRecord(status: status, reason: reason, httpVersion: "HTTP/2", headers: headers)
        guard !holds else { return }
        streamed = true
        write(.headers(.init(headers: Self.responseHeaders(status: status, headers: headers, keepLength: true), endStream: false)))
    }

    func upstreamBody(_ bytes: ByteBuffer) {
        body.append(contentsOf: bytes.readableBytesView)
        if !holds { write(.data(.init(data: .byteBuffer(bytes), endStream: false))) }
    }

    func upstreamEnd(trailers: [HTTPHeader]) {
        guard var response else { return reply502() }
        response.body = body
        response.trailers = trailers
        if streamed {
            if trailers.isEmpty {
                write(.data(.init(data: .byteBuffer(ByteBuffer()), endStream: true)))
            } else {
                write(.headers(.init(headers: Self.trailerHeaders(trailers), endStream: true)))
            }
            record(response)
        } else if holds {
            let scripted = env.rules.applyScripts(to: response, for: flow.request)
            flow.notes += scripted.notes
            conclude(scripted.value)
        } else {
            conclude(response)
        }
    }

    func upstreamFailed(_ error: Error) {
        if streamed { stream.close(promise: nil) } else { reply502() }
    }

    // MARK: Answering

    /// Applies the response breakpoint (if any), then records and writes the whole response.
    private func conclude(_ held: HTTPResponseRecord) {
        guard let pause else { return finish(held) }
        let request = flow.request, loop = stream.eventLoop
        Task {
            let edited = await pause.resume(response: held, for: request)
            loop.execute { self.finish(edited ?? HTTPResponseRecord(status: 499, reason: "Cancelled by Proxio")) }
        }
    }

    private func finish(_ response: HTTPResponseRecord) {
        var response = response
        response.httpVersion = "HTTP/2"
        record(response)
        let hasBody = !response.body.isEmpty, hasTrailers = !response.trailers.isEmpty
        var headers = Self.responseHeaders(status: response.status, headers: response.headers, keepLength: false)
        if hasBody { headers.add(name: "content-length", value: String(response.body.count)) }
        write(.headers(.init(headers: headers, endStream: !hasBody && !hasTrailers)))
        if hasBody { write(.data(.init(data: .byteBuffer(ByteBuffer(bytes: response.body)), endStream: !hasTrailers))) }
        if hasTrailers { write(.headers(.init(headers: Self.trailerHeaders(response.trailers), endStream: true))) }
    }

    private func record(_ response: HTTPResponseRecord) {
        var done = flow
        done.response = response
        done.duration = Date().timeIntervalSince(startedAt)
        done.timings = timing.result()
        let store = env.store
        Task { await store.add(done) }
    }

    private func reply502() { Self.reply(status: 502, on: stream) }

    static func reply(status: Int, on stream: Channel) {
        stream.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders([(":status", String(status)), ("content-length", "0")]), endStream: true)), promise: nil)
    }

    private func write(_ payload: HTTP2Frame.FramePayload) { stream.writeAndFlush(payload, promise: nil) }

    private static func responseHeaders(status: Int, headers: [HTTPHeader], keepLength: Bool) -> HPACKHeaders {
        var fields: [(String, String)] = [(":status", String(status))]
        for h in headers where !isPseudo(h.name) {
            let name = h.name.lowercased()
            if connectionSpecific.contains(name) { continue }
            if name == "content-length" && !keepLength { continue }
            fields.append((name, h.value))
        }
        return HPACKHeaders(fields)
    }

    private static func trailerHeaders(_ trailers: [HTTPHeader]) -> HPACKHeaders {
        HPACKHeaders(trailers.filter { !isPseudo($0.name) }.map { ($0.name.lowercased(), $0.value) })
    }
}
