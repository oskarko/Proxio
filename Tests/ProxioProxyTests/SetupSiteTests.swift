import Testing
import Foundation
import NIOCore
import NIOPosix
import ProxioCore
@testable import ProxioProxy

private final class Collect: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var bytes = Data()
    var data: Data { lock.withLock { bytes } }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let b = unwrapInboundIn(data)
        lock.withLock { bytes.append(contentsOf: b.readableBytesView) }
    }
}

private func fetch(_ request: String, port: Int, group: EventLoopGroup) async throws -> Data {
    let box = Collect()
    let client = try await ClientBootstrap(group: group).channelInitializer { $0.pipeline.addHandler(box) }
        .connect(host: "127.0.0.1", port: port).get()
    try await client.writeAndFlush(ByteBuffer(string: request)).get()
    try await client.closeFuture.get()
    return box.data
}

@Test func proxyServesSetupSiteAndCertificatesWithoutRecordingThem() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let store = FlowStore()
    let ca = try CertificateAuthority()
    let proxy = try ProxyServer(store: store, port: 0, ca: ca, threads: 1)
    let port = try await proxy.start()

    let page = String(decoding: try await fetch("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", port: port, group: group), as: UTF8.self)
    #expect(page.contains("200") && page.contains("proxio.mobileconfig"))

    let profile = String(decoding: try await fetch("GET http://proxio.local/proxio.mobileconfig HTTP/1.1\r\nHost: proxio.local\r\nConnection: close\r\n\r\n", port: port, group: group), as: UTF8.self)
    #expect(profile.contains("application/x-apple-aspen-config") && profile.contains("com.apple.security.root"))

    let der = try await fetch("GET /ca.cer HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", port: port, group: group)
    let expected = try ca.rootCertificateDER
    #expect(der.suffix(expected.count) == expected)

    #expect(await store.all().isEmpty)
    try await proxy.stop()
    try await group.shutdownGracefully()
}

@Test func privateRangesAreRecognised() {
    for ip in ["10.0.0.5", "192.168.1.133", "172.16.0.1", "172.31.255.1", "169.254.1.1", "127.0.0.1"] { #expect(LocalNetwork.isPrivate(ipv4: ip)) }
    for ip in ["8.8.8.8", "172.32.0.1", "11.0.0.1", "192.169.0.1", "not-an-ip"] { #expect(!LocalNetwork.isPrivate(ipv4: ip)) }
}

@Test func mobileConfigEmbedsTheCertificate() throws {
    let der = Data([1, 2, 3, 4])
    let text = String(decoding: MobileConfig.profile(certificateDER: der), as: UTF8.self)
    #expect(text.contains(der.base64EncodedString()))
    #expect(text.contains("<key>PayloadType</key><string>com.apple.security.root</string>"))
    #expect(MobileConfig.profile(certificateDER: der) == MobileConfig.profile(certificateDER: der))   // stable UUIDs
}
