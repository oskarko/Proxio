import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import ProxioCore
@testable import ProxioProxy

/// Minimal upstream: answers every request with "hello" and echoes the path in a header.
private final class HelloHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var uri = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): uri = h.uri
        case .body: break
        case .end:
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain")
            headers.add(name: "Content-Length", value: "5")
            headers.add(name: "X-Path", value: uri)
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: 5)
            buf.writeString("hello")
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }
    }
}

private func startUpstream(_ group: EventLoopGroup) async throws -> Channel {
    try await ServerBootstrap(group: group)
        .childChannelInitializer { ch in ch.pipeline.configureHTTPServerPipeline().flatMap { ch.pipeline.addHandler(HelloHandler()) } }
        .bind(host: "127.0.0.1", port: 0).get()
}

/// Collects raw bytes received on a client connection.
private final class Collector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<String>
    private var text = ""
    init(_ promise: EventLoopPromise<String>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { text += String(buffer: unwrapInboundIn(data)) }
    func channelInactive(context: ChannelHandlerContext) { promise.succeed(text) }
}

@Test func forwardsPlainHTTPAndRecordsFlow() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await startUpstream(group)
    let upstreamPort = upstream.localAddress!.port!

    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0)
    let proxyPort = try await proxy.start()

    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
    ]
    let session = URLSession(configuration: config)
    let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(upstreamPort)/ping?x=1")!)

    #expect(String(data: data, encoding: .utf8) == "hello")
    #expect((response as? HTTPURLResponse)?.statusCode == 200)

    try await Task.sleep(nanoseconds: 200_000_000)
    let flows = await store.all()
    #expect(flows.count == 1)
    #expect(flows.first?.request.url.path == "/ping")
    #expect(flows.first?.request.url.query == "x=1")
    #expect(flows.first?.response?.status == 200)
    #expect(flows.first?.response?.mimeType == "text/plain")
    #expect(flows.first?.response.flatMap { String(data: $0.body, encoding: .utf8) } == "hello")

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}

@Test func tunnelsConnectAndRecordsIt() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await startUpstream(group)
    let upstreamPort = upstream.localAddress!.port!

    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0)
    let proxyPort = try await proxy.start()

    let done = group.next().makePromise(of: String.self)
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { $0.pipeline.addHandler(Collector(done)) }
        .connect(host: "127.0.0.1", port: proxyPort).get()

    let connect = "CONNECT 127.0.0.1:\(upstreamPort) HTTP/1.1\r\nHost: 127.0.0.1:\(upstreamPort)\r\n\r\n"
    try await client.writeAndFlush(ByteBuffer(string: connect)).get()
    try await Task.sleep(nanoseconds: 300_000_000)
    let inner = "GET /tunnel HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    try await client.writeAndFlush(ByteBuffer(string: inner)).get()

    let received = try await done.futureResult.get()
    #expect(received.hasPrefix("HTTP/1.1 200 Connection Established"))
    #expect(received.contains("X-Path: /tunnel"))
    #expect(received.hasSuffix("hello"))

    let flows = await store.all()
    #expect(flows.first?.request.method == "CONNECT")

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}

@Test func rejectsUnreachableUpstreamWith502() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let proxy = try ProxyServer(store: FlowStore(), port: 0)
    let proxyPort = try await proxy.start()

    let done = group.next().makePromise(of: String.self)
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { $0.pipeline.addHandler(Collector(done)) }
        .connect(host: "127.0.0.1", port: proxyPort).get()
    try await client.writeAndFlush(ByteBuffer(string: "CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n")).get()
    #expect(try await done.futureResult.get().hasPrefix("HTTP/1.1 502"))

    try await proxy.stop()
    try await group.shutdownGracefully()
}

@Test func parsesHostAndPort() {
    #expect(ProxyFrontendHandler.hostPort(from: "example.com:8443", defaultPort: 443)! == ("example.com", 8443))
    #expect(ProxyFrontendHandler.hostPort(from: "example.com", defaultPort: 443)! == ("example.com", 443))
    #expect(ProxyFrontendHandler.hostPort(from: ":80", defaultPort: 443) == nil)
}

// MARK: - TLS interception

/// Fires once the proxy's plain `200` reply to CONNECT has been read, then removes itself.
private final class ConnectReply: ChannelInboundHandler, RemovableChannelHandler {
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

@Test func caIssuesPerHostContextsAndPersists() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("proxio-ca-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let ca = try CertificateAuthority.loadOrCreate(in: dir)
    _ = try ca.serverContext(for: "example.com")
    _ = try ca.serverContext(for: "127.0.0.1")
    _ = try ca.serverContext(for: "::1")
    let pem = try ca.rootCertificatePEM
    #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----"))

    let reloaded = try CertificateAuthority.loadOrCreate(in: dir)
    #expect(try reloaded.rootCertificatePEM == pem)
    let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("ca-key.pem").path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
}

@Test func interceptsHTTPSAndRecordsDecryptedFlow() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    // Origin server with its own CA, which only the proxy trusts.
    let originCA = try CertificateAuthority(commonName: "Origin Test CA")
    let originContext = try originCA.serverContext(for: "localhost")
    let origin = try await ServerBootstrap(group: group)
        .childChannelInitializer { ch in
            ch.pipeline.addHandler(NIOSSLServerHandler(context: originContext))
                .flatMap { ch.pipeline.configureHTTPServerPipeline() }
                .flatMap { ch.pipeline.addHandler(HelloHandler()) }
        }
        .bind(host: "127.0.0.1", port: 0).get()
    let originPort = origin.localAddress!.port!

    var upstreamTLS = TLSConfiguration.makeClientConfiguration()
    upstreamTLS.trustRoots = .certificates([try nioCert(try originCA.rootCertificatePEM)])

    let proxioCA = try CertificateAuthority()
    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0, ca: proxioCA, upstreamTLS: upstreamTLS)
    let proxyPort = try await proxy.start()

    // Client trusts only the Proxio CA.
    var clientTLS = TLSConfiguration.makeClientConfiguration()
    clientTLS.trustRoots = .certificates([try nioCert(try proxioCA.rootCertificatePEM)])
    clientTLS.applicationProtocols = ["http/1.1"]
    let clientContext = try NIOSSLContext(configuration: clientTLS)

    let connected = group.next().makePromise(of: String.self)
    let done = group.next().makePromise(of: String.self)
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { $0.pipeline.addHandler(ConnectReply(connected)) }
        .connect(host: "127.0.0.1", port: proxyPort).get()

    try await client.writeAndFlush(ByteBuffer(string: "CONNECT localhost:\(originPort) HTTP/1.1\r\nHost: localhost:\(originPort)\r\n\r\n")).get()
    let reply = try await connected.futureResult.get()
    #expect(reply.hasPrefix("HTTP/1.1 200 Connection Established"))

    try await client.pipeline.addHandler(NIOSSLClientHandler(context: clientContext, serverHostname: "localhost"), position: .first).get()
    try await client.pipeline.addHandler(Collector(done)).get()
    try await client.writeAndFlush(ByteBuffer(string: "GET /secure?a=1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")).get()

    let received = try await done.futureResult.get()
    #expect(received.hasPrefix("HTTP/1.1 200 OK"))
    #expect(received.contains("X-Path: /secure?a=1"))
    #expect(received.hasSuffix("hello"))

    try await Task.sleep(nanoseconds: 200_000_000)
    let flows = await store.all()
    #expect(flows.count == 2)
    #expect(flows.first?.request.method == "CONNECT")
    let decrypted = flows.first { $0.request.method == "GET" }
    #expect(decrypted?.request.url.absoluteString == "https://localhost:\(originPort)/secure?a=1")
    #expect(decrypted?.response?.status == 200)
    #expect(decrypted?.response.flatMap { String(data: $0.body, encoding: .utf8) } == "hello")

    try await proxy.stop()
    try await origin.close().get()
    try await group.shutdownGracefully()
}

@Test func clientRejectsInterceptedCertWhenCANotTrusted() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let proxy = try ProxyServer(store: FlowStore(), port: 0, ca: try CertificateAuthority())
    let proxyPort = try await proxy.start()

    // Default system trust: the Proxio CA is not installed, so the handshake must fail.
    let clientContext = try NIOSSLContext(configuration: .makeClientConfiguration())
    let connected = group.next().makePromise(of: String.self)
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { $0.pipeline.addHandler(ConnectReply(connected)) }
        .connect(host: "127.0.0.1", port: proxyPort).get()
    try await client.writeAndFlush(ByteBuffer(string: "CONNECT localhost:1 HTTP/1.1\r\n\r\n")).get()
    _ = try await connected.futureResult.get()

    let closed = group.next().makePromise(of: String.self)
    try await client.pipeline.addHandler(NIOSSLClientHandler(context: clientContext, serverHostname: "localhost"), position: .first).get()
    try await client.pipeline.addHandler(Collector(closed)).get()
    try? await client.writeAndFlush(ByteBuffer(string: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")).get()
    #expect(try await closed.futureResult.get().isEmpty)

    try await proxy.stop()
    try await group.shutdownGracefully()
}

@Test func excludedHostIsTunnelledOpaquelyEvenWithCA() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await startUpstream(group)   // plain HTTP: would break if the proxy tried TLS
    let upstreamPort = upstream.localAddress!.port!

    let policy = SSLProxyingPolicy(SSLProxyingRules(exclude: [HostPattern("127.0.0.1")!], interceptByDefault: true))
    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0, ca: try CertificateAuthority(), sslProxying: policy)
    let proxyPort = try await proxy.start()

    let done = group.next().makePromise(of: String.self)
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { $0.pipeline.addHandler(Collector(done)) }
        .connect(host: "127.0.0.1", port: proxyPort).get()
    try await client.writeAndFlush(ByteBuffer(string: "CONNECT 127.0.0.1:\(upstreamPort) HTTP/1.1\r\n\r\n")).get()
    try await Task.sleep(nanoseconds: 300_000_000)
    try await client.writeAndFlush(ByteBuffer(string: "GET /raw HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")).get()

    let received = try await done.futureResult.get()
    #expect(received.contains("X-Path: /raw"))
    #expect(await store.all().map(\.request.method) == ["CONNECT"])

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}

// MARK: - Breakpoints

/// Echoes the received method, body and a custom header back, so edits made at a breakpoint are observable.
private final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?
    private var body = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): head = h
        case .body(let b): body += String(buffer: b)
        case .end:
            let text = "\(head?.method.rawValue ?? "") \(head?.uri ?? "") x-edit=\(head?.headers["X-Edit"].first ?? "-") host=\(head?.headers["Host"].first ?? "-") body=\(body)"
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain")
            headers.add(name: "Content-Length", value: String(text.utf8.count))
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: text)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }
    }
}

private func startEchoUpstream(_ group: EventLoopGroup) async throws -> Channel {
    try await ServerBootstrap(group: group)
        .childChannelInitializer { ch in ch.pipeline.configureHTTPServerPipeline().flatMap { ch.pipeline.addHandler(EchoHandler()) } }
        .bind(host: "127.0.0.1", port: 0).get()
}

private struct ScriptedBreakpoints: BreakpointHandler {
    var editRequest: (@Sendable (HTTPRequestRecord) -> HTTPRequestRecord?)?
    var editResponse: (@Sendable (HTTPResponseRecord) -> HTTPResponseRecord?)?
    func resume(request: HTTPRequestRecord) async -> HTTPRequestRecord? {
        try? await Task.sleep(nanoseconds: 50_000_000)   // simulates a person looking at it
        return editRequest.map { $0(request) } ?? request
    }
    func resume(response: HTTPResponseRecord, for request: HTTPRequestRecord) async -> HTTPResponseRecord? {
        try? await Task.sleep(nanoseconds: 50_000_000)
        return editResponse.map { $0(response) } ?? response
    }
}

private func proxiedSession(port: Int) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port]
    return URLSession(configuration: config)
}

@Test func requestBreakpointEditsWhatReachesTheServer() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await startEchoUpstream(group)
    let upstreamPort = upstream.localAddress!.port!

    let rules = TrafficRules()
    rules.breakpoints = [Breakpoint(matcher: RequestMatcher(urlPattern: "127.0.0.1:\(upstreamPort)"), onRequest: true, onResponse: false)]
    rules.breakpointHandler = ScriptedBreakpoints(editRequest: { r in
        var r = r
        r.method = "PUT"
        r.url = URL(string: "http://127.0.0.1:\(upstreamPort)/edited?a=1")!
        r.headers.append(HTTPHeader(name: "X-Edit", value: "yes"))
        r.body = Data("changed".utf8)
        return r
    })
    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0, rules: rules)
    let proxyPort = try await proxy.start()

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(upstreamPort)/original")!)
    request.httpMethod = "POST"
    request.httpBody = Data("original body".utf8)
    let (data, _) = try await proxiedSession(port: proxyPort).data(for: request)
    #expect(String(data: data, encoding: .utf8) == "PUT /edited?a=1 x-edit=yes host=127.0.0.1:\(upstreamPort) body=changed")

    try await Task.sleep(nanoseconds: 200_000_000)
    let flow = await store.all().first
    #expect(flow?.request.method == "PUT")
    #expect(flow?.request.url.path == "/edited")

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}

@Test func responseBreakpointEditsWhatTheClientReceives() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await startUpstream(group)
    let upstreamPort = upstream.localAddress!.port!

    let rules = TrafficRules()
    rules.breakpoints = [Breakpoint(matcher: RequestMatcher(urlPattern: "*"), onRequest: false, onResponse: true)]
    rules.breakpointHandler = ScriptedBreakpoints(editResponse: { r in
        var r = r
        r.status = 201
        r.reason = "Created"
        r.headers.append(HTTPHeader(name: "X-Edited", value: "1"))
        r.body = Data("edited response, longer than before".utf8)
        return r
    })
    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0, rules: rules)
    let proxyPort = try await proxy.start()

    let (data, response) = try await proxiedSession(port: proxyPort).data(from: URL(string: "http://127.0.0.1:\(upstreamPort)/ping")!)
    let http = response as? HTTPURLResponse
    #expect(http?.statusCode == 201)
    #expect(http?.value(forHTTPHeaderField: "X-Edited") == "1")
    #expect(String(data: data, encoding: .utf8) == "edited response, longer than before")

    try await Task.sleep(nanoseconds: 200_000_000)
    let flow = await store.all().first
    #expect(flow?.response?.status == 201)

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}

@Test func cancellingAtABreakpointAnswers499() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await startUpstream(group)
    let upstreamPort = upstream.localAddress!.port!

    let rules = TrafficRules()
    rules.breakpoints = [Breakpoint(matcher: RequestMatcher(urlPattern: "*"))]
    rules.breakpointHandler = ScriptedBreakpoints(editRequest: { _ in nil })
    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0, rules: rules)
    let proxyPort = try await proxy.start()

    let (_, response) = try await proxiedSession(port: proxyPort).data(from: URL(string: "http://127.0.0.1:\(upstreamPort)/x")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 499)
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(await store.all().first?.response?.status == 499)

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}

// MARK: - Map Local / Map Remote

@Test func mapLocalAnswersWithoutContactingTheServer() async throws {
    let rules = TrafficRules()
    rules.mapLocalRules = [MapLocalRule(
        matcher: RequestMatcher(urlPattern: "unreachable.invalid/*"),
        status: 202, headers: [HTTPHeader(name: "X-Mock", value: "1")], body: Data(#"{"mocked":true}"#.utf8)
    )]
    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0, rules: rules)
    let proxyPort = try await proxy.start()

    let (data, response) = try await proxiedSession(port: proxyPort).data(from: URL(string: "http://unreachable.invalid/api/thing")!)
    let http = response as? HTTPURLResponse
    #expect(http?.statusCode == 202)
    #expect(http?.value(forHTTPHeaderField: "X-Mock") == "1")
    #expect(http?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(String(data: data, encoding: .utf8) == #"{"mocked":true}"#)

    try await Task.sleep(nanoseconds: 200_000_000)
    let flow = await store.all().first
    #expect(flow?.notes == ["Map Local"])
    #expect(flow?.response?.status == 202)

    try await proxy.stop()
}

@Test func mapRemoteSendsTheRequestToAnotherHost() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let upstream = try await startEchoUpstream(group)
    let upstreamPort = upstream.localAddress!.port!

    let rules = TrafficRules()
    rules.mapRemoteRules = [MapRemoteRule(matcher: RequestMatcher(urlPattern: "unreachable.invalid"), host: "127.0.0.1", port: upstreamPort, path: "/redirected")]
    let store = FlowStore()
    let proxy = try ProxyServer(store: store, port: 0, rules: rules)
    let proxyPort = try await proxy.start()

    let (data, _) = try await proxiedSession(port: proxyPort).data(from: URL(string: "http://unreachable.invalid/original?q=1")!)
    #expect(String(data: data, encoding: .utf8) == "GET /redirected?q=1 x-edit=- host=127.0.0.1:\(upstreamPort) body=")

    try await Task.sleep(nanoseconds: 200_000_000)
    let flow = await store.all().first
    #expect(flow?.request.url.host == "127.0.0.1")
    #expect(flow?.notes.first?.hasPrefix("Map Remote") == true)

    try await proxy.stop()
    try await upstream.close().get()
    try await group.shutdownGracefully()
}

@Test func mapLocalResponseCanBeHeldAtABreakpoint() async throws {
    let rules = TrafficRules()
    rules.mapLocalRules = [MapLocalRule(matcher: RequestMatcher(urlPattern: "unreachable.invalid"), body: Data("original".utf8))]
    rules.breakpoints = [Breakpoint(matcher: RequestMatcher(urlPattern: "*"), onRequest: false, onResponse: true)]
    rules.breakpointHandler = ScriptedBreakpoints(editResponse: { r in var r = r; r.body = Data("tweaked".utf8); return r })
    let proxy = try ProxyServer(store: FlowStore(), port: 0, rules: rules)
    let proxyPort = try await proxy.start()

    let (data, _) = try await proxiedSession(port: proxyPort).data(from: URL(string: "http://unreachable.invalid/")!)
    #expect(String(data: data, encoding: .utf8) == "tweaked")
    try await proxy.stop()
}
