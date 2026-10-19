import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHPACK
import NIOHTTP2
import NIOSSL
import NIOTLS
import ProxioCore
@testable import ProxioProxy

/// Origin that speaks HTTP/2 and answers like a unary gRPC server: echoes the request body as
/// the response message and finishes with `grpc-status: 0` in the trailers.
private final class GRPCEchoStream: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload
    private var body = ByteBuffer()
    private var path = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .headers(let h):
            if path.isEmpty { path = h.headers[":path"].first ?? "" }
            if h.endStream { respond(context) }
        case .data(let d):
            if case .byteBuffer(var buf) = d.data { body.writeBuffer(&buf) }
            if d.endStream { respond(context) }
        default: break
        }
    }

    private func respond(_ context: ChannelHandlerContext) {
        context.write(wrapOutboundOut(.headers(.init(headers: ["x-path": path].merging(status: "200", type: "application/grpc"), endStream: false))), promise: nil)
        context.write(wrapOutboundOut(.data(.init(data: .byteBuffer(body), endStream: false))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.headers(.init(headers: ["grpc-status": "0"], endStream: true))), promise: nil)
    }
}

private extension Dictionary where Key == String, Value == String {
    func merging(status: String, type: String) -> HPACKHeaders {
        var fields: [(String, String)] = [(":status", status), ("content-type", type)]
        fields += map { ($0.key, $0.value) }
        return HPACKHeaders(fields)
    }
}

private func startH2Origin(_ group: EventLoopGroup, ca: CertificateAuthority) async throws -> Channel {
    let context = try ca.serverContext(for: "localhost", applicationProtocols: ["h2"])
    return try await ServerBootstrap(group: group)
        .childChannelInitializer { ch in
            ch.pipeline.addHandler(NIOSSLServerHandler(context: context)).flatMap {
                ch.configureHTTP2Pipeline(mode: .server) { stream in stream.pipeline.addHandler(GRPCEchoStream()) }.map { _ in }
            }
        }
        .bind(host: "127.0.0.1", port: 0).get()
}

private struct H2Answer {
    var headers: [String: String] = [:]
    var body = Data()
    var trailers: [String: String] = [:]
}

private final class H2Collector: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    let done: EventLoopPromise<H2Answer>
    private var answer = H2Answer()
    private var sawHead = false
    init(_ done: EventLoopPromise<H2Answer>) { self.done = done }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .headers(let h):
            let fields = Dictionary(h.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
            if sawHead { answer.trailers = fields } else { answer.headers = fields; sawHead = true }
            if h.endStream { done.succeed(answer) }
        case .data(let d):
            if case .byteBuffer(let buf) = d.data { answer.body.append(contentsOf: buf.readableBytesView) }
            if d.endStream { done.succeed(answer) }
        default: break
        }
    }
}

/// Connects through the proxy to `localhost:originPort`, negotiates `h2` with the forged certificate and sends one POST.
private func h2Post(group: EventLoopGroup, proxyPort: Int, originPort: Int, trusting ca: CertificateAuthority, path: String, body: Data) async throws -> H2Answer {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.trustRoots = .certificates([try nioCert(try ca.rootCertificatePEM)])
    tls.applicationProtocols = ["h2"]
    let context = try NIOSSLContext(configuration: tls)

    let connected = group.next().makePromise(of: String.self)
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { $0.pipeline.addHandler(ConnectBytes(connected)) }
        .connect(host: "127.0.0.1", port: proxyPort).get()
    try await client.writeAndFlush(ByteBuffer(string: "CONNECT localhost:\(originPort) HTTP/1.1\r\nHost: localhost:\(originPort)\r\n\r\n")).get()
    #expect(try await connected.futureResult.get().hasPrefix("HTTP/1.1 200"))

    // HTTP/2 goes on after the handshake, once ALPN has said `h2`.
    let ready = group.next().makePromise(of: HTTP2StreamMultiplexer.self)
    let alpn = ApplicationProtocolNegotiationHandler { result, channel in
        guard case .negotiated("h2") = result else { return channel.eventLoop.makeFailedFuture(ChannelError.inappropriateOperationForState) }
        return channel.configureHTTP2Pipeline(mode: .client, inboundStreamInitializer: nil).map { ready.succeed($0) }
    }
    try await client.pipeline.addHandlers([NIOSSLClientHandler(context: context, serverHostname: "localhost"), alpn], position: .first).get()
    let multiplexer = try await ready.futureResult.get()
    let done = group.next().makePromise(of: H2Answer.self)
    let stream = try await multiplexer.createStreamChannel { $0.pipeline.addHandler(H2Collector(done)) }.get()

    let headers = HPACKHeaders([
        (":method", "POST"), (":scheme", "https"), (":authority", "localhost:\(originPort)"), (":path", path),
        ("content-type", "application/grpc"), ("te", "trailers"),
    ])
    try await stream.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false))).get()
    try await stream.writeAndFlush(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(bytes: body)), endStream: true))).get()
    let answer = try await done.futureResult.get()
    try await client.close().get()
    return answer
}

/// Passes everything on after the proxy's CONNECT reply, which ends at the first blank line.
private final class ConnectBytes: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<String>
    private var text = ""
    init(_ promise: EventLoopPromise<String>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        text += String(buffer: unwrapInboundIn(data))
        if text.contains("\r\n\r\n") {
            promise.succeed(text)
            context.pipeline.removeHandler(self, promise: nil)
        }
    }
}

private func nioCert(_ pem: String) throws -> NIOSSLCertificate {
    try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem)
}

@Test func http2ClientReachesHTTP2OriginAndKeepsGRPCTrailers() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let originCA = try CertificateAuthority(commonName: "Origin H2 CA")
    let origin = try await startH2Origin(group, ca: originCA)
    let originPort = origin.localAddress!.port!

    var upstreamTLS = TLSConfiguration.makeClientConfiguration()
    upstreamTLS.trustRoots = .certificates([try nioCert(try originCA.rootCertificatePEM)])
    let proxioCA = try CertificateAuthority()
    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0, ca: proxioCA, upstreamTLS: upstreamTLS)
    let proxyPort = try await proxy.start()

    // One gRPC frame: flag 0, length 3, payload 0x08 0x96 0x01 (field 1 = 150).
    let message = Data([0, 0, 0, 0, 3, 0x08, 0x96, 0x01])
    let answer = try await h2Post(group: group, proxyPort: proxyPort, originPort: originPort, trusting: proxioCA, path: "/pkg.Echo/Say", body: message)
    #expect(answer.headers[":status"] == "200")
    #expect(answer.headers["x-path"] == "/pkg.Echo/Say")
    #expect(answer.body == message)
    #expect(answer.trailers["grpc-status"] == "0")

    try await Task.sleep(nanoseconds: 200_000_000)
    let flow = try #require(await store.all().first { $0.request.method == "POST" })
    #expect(flow.request.httpVersion == "HTTP/2")
    #expect(flow.request.url.absoluteString == "https://localhost:\(originPort)/pkg.Echo/Say")
    #expect(flow.request.body == message)
    #expect(flow.response?.httpVersion == "HTTP/2")
    #expect(flow.response?.body == message)
    #expect(flow.response?.trailers.contains { $0.name == "grpc-status" && $0.value == "0" } == true)

    try await proxy.stop()
    try await origin.close().get()
    try await group.shutdownGracefully()
}

@Test func http2ClientIsServedByHTTP1Origin() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let originCA = try CertificateAuthority(commonName: "Origin H1 CA")
    let context = try originCA.serverContext(for: "localhost", applicationProtocols: ["http/1.1"])
    let origin = try await ServerBootstrap(group: group)
        .childChannelInitializer { ch in
            ch.pipeline.addHandler(NIOSSLServerHandler(context: context))
                .flatMap { ch.pipeline.configureHTTPServerPipeline() }
                .flatMap { ch.pipeline.addHandler(EchoBodyHandler()) }
        }
        .bind(host: "127.0.0.1", port: 0).get()
    let originPort = origin.localAddress!.port!

    var upstreamTLS = TLSConfiguration.makeClientConfiguration()
    upstreamTLS.trustRoots = .certificates([try nioCert(try originCA.rootCertificatePEM)])
    let proxioCA = try CertificateAuthority()
    let rules = TrafficRules()
    let proxy = try ProxyServer(store: FlowStore(), port: 0, ca: proxioCA, upstreamTLS: upstreamTLS, rules: rules)
    let proxyPort = try await proxy.start()

    let answer = try await h2Post(group: group, proxyPort: proxyPort, originPort: originPort, trusting: proxioCA, path: "/plain", body: Data("ping".utf8))
    #expect(answer.headers[":status"] == "200")
    #expect(String(decoding: answer.body, as: UTF8.self) == "echo:ping")
    #expect(answer.headers["connection"] == nil)   // hop-by-hop headers never cross into h2

    try await proxy.stop()
    try await origin.close().get()
    try await group.shutdownGracefully()
}

private final class EchoBodyHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var body = Data()
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head: body = Data()
        case .body(let buf): body.append(contentsOf: buf.readableBytesView)
        case .end:
            let reply = Data("echo:".utf8) + body
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: String(reply.count))
            headers.add(name: "Connection", value: "close")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: reply)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }
    }
}

private struct EditResponse: BreakpointHandler {
    func resume(request: HTTPRequestRecord) async -> HTTPRequestRecord? { request }
    func resume(response: HTTPResponseRecord, for request: HTTPRequestRecord) async -> HTTPResponseRecord? {
        var edited = response
        edited.body = Data("edited".utf8)
        return edited
    }
}

@Test func http2ResponseBreakpointEditsBodyAndKeepsTrailers() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let originCA = try CertificateAuthority(commonName: "Origin H2 CA")
    let origin = try await startH2Origin(group, ca: originCA)
    let originPort = origin.localAddress!.port!

    var upstreamTLS = TLSConfiguration.makeClientConfiguration()
    upstreamTLS.trustRoots = .certificates([try nioCert(try originCA.rootCertificatePEM)])
    let proxioCA = try CertificateAuthority()
    let rules = TrafficRules()
    rules.breakpoints = [Breakpoint(matcher: RequestMatcher(urlPattern: "*"), onRequest: false, onResponse: true)]
    rules.breakpointHandler = EditResponse()
    let proxy = try ProxyServer(store: FlowStore(), port: 0, ca: proxioCA, upstreamTLS: upstreamTLS, rules: rules)
    let proxyPort = try await proxy.start()

    let answer = try await h2Post(group: group, proxyPort: proxyPort, originPort: originPort, trusting: proxioCA, path: "/held", body: Data("original".utf8))
    #expect(String(decoding: answer.body, as: UTF8.self) == "edited")
    #expect(answer.headers["content-length"] == "6")
    #expect(answer.trailers["grpc-status"] == "0")

    try await proxy.stop()
    try await origin.close().get()
    try await group.shutdownGracefully()
}

@Test func http2MapLocalAnswersWithoutTouchingTheOrigin() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let proxioCA = try CertificateAuthority()
    let rules = TrafficRules()
    rules.mapLocalRules = [MapLocalRule(matcher: RequestMatcher(urlPattern: "*"), status: 201, headers: [HTTPHeader(name: "X-Local", value: "yes")], body: Data("mocked".utf8))]
    let proxy = try ProxyServer(store: FlowStore(), port: 0, ca: proxioCA, rules: rules)
    let proxyPort = try await proxy.start()

    // Nothing listens on this port: only a local answer can succeed.
    let answer = try await h2Post(group: group, proxyPort: proxyPort, originPort: 9, trusting: proxioCA, path: "/mock", body: Data())
    #expect(answer.headers[":status"] == "201")
    #expect(answer.headers["x-local"] == "yes")
    #expect(String(decoding: answer.body, as: UTF8.self) == "mocked")

    try await proxy.stop()
    try await group.shutdownGracefully()
}

// MARK: Upstream connection reuse

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// HTTP/1.1 origin handler that keeps the connection open and counts accepted connections.
private final class KeepAliveEcho: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let accepted: Counter
    private var body = Data()
    init(accepted: Counter) { self.accepted = accepted }
    func channelActive(context: ChannelHandlerContext) { accepted.bump(); context.fireChannelActive() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head: body = Data()
        case .body(let buf): body.append(contentsOf: buf.readableBytesView)
        case .end:
            let reply = Data("echo:".utf8) + body
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: String(reply.count))
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: reply)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

@Test func http1OriginConnectionIsReusedAcrossRequests() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let originCA = try CertificateAuthority(commonName: "Origin Reuse CA")
    let context = try originCA.serverContext(for: "localhost", applicationProtocols: ["http/1.1"])
    let accepted = Counter()
    let origin = try await ServerBootstrap(group: group)
        .childChannelInitializer { ch in
            ch.pipeline.addHandler(NIOSSLServerHandler(context: context))
                .flatMap { ch.pipeline.configureHTTPServerPipeline() }
                .flatMap { ch.pipeline.addHandler(KeepAliveEcho(accepted: accepted)) }
        }
        .bind(host: "127.0.0.1", port: 0).get()
    let originPort = origin.localAddress!.port!

    var upstreamTLS = TLSConfiguration.makeClientConfiguration()
    upstreamTLS.trustRoots = .certificates([try nioCert(try originCA.rootCertificatePEM)])
    let proxioCA = try CertificateAuthority()
    let proxy = try ProxyServer(store: FlowStore(), port: 0, ca: proxioCA, upstreamTLS: upstreamTLS, threads: 1)
    let proxyPort = try await proxy.start()

    for word in ["one", "two", "three"] {
        let answer = try await h2Post(group: group, proxyPort: proxyPort, originPort: originPort, trusting: proxioCA, path: "/r", body: Data(word.utf8))
        #expect(String(decoding: answer.body, as: UTF8.self) == "echo:\(word)")
    }
    #expect(accepted.value == 1)

    try await proxy.stop()
    try await origin.close().get()
    try await group.shutdownGracefully()
}

@Test func http2OriginConnectionIsSharedAcrossRequests() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let originCA = try CertificateAuthority(commonName: "Origin H2 Share CA")
    let context = try originCA.serverContext(for: "localhost", applicationProtocols: ["h2"])
    let accepted = Counter()
    let origin = try await ServerBootstrap(group: group)
        .childChannelInitializer { ch in
            accepted.bump()
            return ch.pipeline.addHandler(NIOSSLServerHandler(context: context)).flatMap {
                ch.configureHTTP2Pipeline(mode: .server) { stream in stream.pipeline.addHandler(GRPCEchoStream()) }.map { _ in }
            }
        }
        .bind(host: "127.0.0.1", port: 0).get()
    let originPort = origin.localAddress!.port!

    var upstreamTLS = TLSConfiguration.makeClientConfiguration()
    upstreamTLS.trustRoots = .certificates([try nioCert(try originCA.rootCertificatePEM)])
    let proxioCA = try CertificateAuthority()
    let proxy = try ProxyServer(store: FlowStore(), port: 0, ca: proxioCA, upstreamTLS: upstreamTLS, threads: 1)
    let proxyPort = try await proxy.start()

    let message = Data([0, 0, 0, 0, 3, 0x08, 0x96, 0x01])
    for _ in 0..<3 {
        let answer = try await h2Post(group: group, proxyPort: proxyPort, originPort: originPort, trusting: proxioCA, path: "/pkg.Echo/Say", body: message)
        #expect(answer.body == message)
        #expect(answer.trailers["grpc-status"] == "0")
    }
    #expect(accepted.value == 1)

    try await proxy.stop()
    try await origin.close().get()
    try await group.shutdownGracefully()
}
