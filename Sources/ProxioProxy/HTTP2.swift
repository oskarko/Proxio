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
// One request is one upstream connection, so streams are never multiplexed upstream.

/// Callbacks from an upstream connection, always on the event loop it was opened on.
protocol UpstreamDelegate: AnyObject {
    func upstreamHead(status: Int, reason: String, headers: [HTTPHeader])
    func upstreamBody(_ bytes: ByteBuffer)
    func upstreamEnd(trailers: [HTTPHeader])
    func upstreamFailed(_ error: Error)
}

enum UpstreamError: Error { case badRequest, closed }

/// Headers that describe one HTTP/1.1 connection and must not cross into HTTP/2 (RFC 9113 §8.2.2).
private let connectionSpecific: Set<String> = ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "host"]

private func isPseudo(_ name: String) -> Bool { name.hasPrefix(":") }

enum UpstreamConnection {
    /// Sends `request` to the origin it names and reports the answer to `delegate`.
    static func open(request: HTTPRequestRecord, env: ProxyEnvironment, loop: EventLoop, delegate: UpstreamDelegate) {
        let url = request.url
        guard let host = url.host, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return delegate.upstreamFailed(UpstreamError.badRequest)
        }
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
        let sending = request

        ClientBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if useTLS {
                        let ssl = try NIOSSLClientHandler(
                            context: env.upstreamH2SSLContext,
                            serverHostname: ProxyFrontendHandler.isIPAddress(host) ? nil : host
                        )
                        let alpn = ApplicationProtocolNegotiationHandler { result, channel in
                            if case .negotiated(let protocolName) = result, protocolName == "h2" {
                                return sendHTTP2(sending, path: path, authority: authority, channel: channel, delegate: delegate)
                            }
                            return sendHTTP1(sending, path: path, authority: authority, channel: channel, delegate: delegate)
                        }
                        try channel.pipeline.syncOperations.addHandlers([ssl, alpn])
                    }
                }
            }
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case .failure(let error): delegate.upstreamFailed(error)
                case .success(let channel):
                    if !useTLS {
                        sendHTTP1(sending, path: path, authority: authority, channel: channel, delegate: delegate)
                            .whenFailure { delegate.upstreamFailed($0) }
                    }
                }
            }
    }

    // MARK: HTTP/1.1

    @discardableResult
    private static func sendHTTP1(_ request: HTTPRequestRecord, path: String, authority: String, channel: Channel, delegate: UpstreamDelegate) -> EventLoopFuture<Void> {
        var headers = HTTPHeaders()
        for h in request.headers where !isPseudo(h.name) { headers.add(name: h.name, value: h.value) }
        for name in ["Proxy-Connection", "Transfer-Encoding", "Content-Length", "Connection", "Keep-Alive", "Upgrade", "TE", "Host"] { headers.remove(name: name) }
        headers.add(name: "Host", value: authority)
        headers.add(name: "Connection", value: "close")
        if !request.body.isEmpty || ["POST", "PUT", "PATCH"].contains(request.method.uppercased()) {
            headers.add(name: "Content-Length", value: String(request.body.count))
        }
        let head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: request.method), uri: path, headers: headers)
        let body = request.body
        return channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandlers([
                HTTPRequestEncoder(),
                ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                HTTP1UpstreamHandler(delegate: delegate),
            ])
        }.map {
            channel.write(HTTPClientRequestPart.head(head), promise: nil)
            if !body.isEmpty { channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil) }
            channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
        }
    }

    // MARK: HTTP/2

    private static func sendHTTP2(_ request: HTTPRequestRecord, path: String, authority: String, channel: Channel, delegate: UpstreamDelegate) -> EventLoopFuture<Void> {
        var fields: [(String, String)] = [
            (":method", request.method), (":scheme", request.url.scheme ?? "https"),
            (":authority", authority), (":path", path),
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

        return channel.configureHTTP2Pipeline(mode: .client, inboundStreamInitializer: nil).flatMap { multiplexer in
            let streamReady = channel.eventLoop.makePromise(of: Channel.self)
            multiplexer.createStreamChannel(promise: streamReady) { stream in
                stream.pipeline.addHandler(HTTP2UpstreamHandler(delegate: delegate))
            }
            return streamReady.futureResult
        }.map { stream in
            stream.write(HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: body.isEmpty)), promise: nil)
            if !body.isEmpty {
                stream.write(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(bytes: body)), endStream: true)), promise: nil)
            }
            stream.flush()
        }
    }
}

/// Reports an HTTP/1.1 origin response and hangs up (the request asked for `Connection: close`).
private final class HTTP1UpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private var delegate: UpstreamDelegate?
    init(delegate: UpstreamDelegate) { self.delegate = delegate }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            delegate?.upstreamHead(
                status: Int(h.status.code), reason: h.status.reasonPhrase,
                headers: h.headers.map { HTTPHeader(name: $0.name, value: $0.value) }
            )
        case .body(let buf): delegate?.upstreamBody(buf)
        case .end(let trailers):
            let d = delegate
            delegate = nil
            d?.upstreamEnd(trailers: trailers?.map { HTTPHeader(name: $0.name, value: $0.value) } ?? [])
            context.close(promise: nil)
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
        d?.upstreamFailed(error)
    }
}

/// Reads one HTTP/2 response stream from an origin.
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
        context.channel.parent?.close(promise: nil)
    }
    private func fail(_ context: ChannelHandlerContext, _ error: Error) {
        let d = delegate
        delegate = nil
        d?.upstreamFailed(error)
        context.channel.parent?.close(promise: nil)
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

    init(environment: ProxyEnvironment, stream: Channel, startedAt: Date) {
        self.env = environment
        self.stream = stream
        self.startedAt = startedAt
        self.flow = Flow(startedAt: startedAt, request: HTTPRequestRecord(method: "", url: URL(string: "about:blank")!))
    }

    func start(_ request: HTTPRequestRecord) {
        let (prepared, local) = env.prepare(request, startedAt: startedAt)
        flow = prepared
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

    func upstreamHead(status: Int, reason: String, headers: [HTTPHeader]) {
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
