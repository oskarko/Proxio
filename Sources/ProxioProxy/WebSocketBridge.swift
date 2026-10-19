import Foundation
import NIOCore
import NIOHTTP1
import ProxioCore

/// Orders store writes for one WebSocket connection: the flow first, then its messages.
final class WebSocketRecorder: @unchecked Sendable {
    private let store: FlowStore
    private let flowID: UUID
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    init(store: FlowStore, flow: Flow) {
        self.store = store
        self.flowID = flow.id
        enqueue { await store.add(flow) }
    }

    func record(_ message: WebSocketMessage) {
        let store = store, id = flowID
        enqueue { await store.append(message, to: id) }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        let previous = tail
        tail = Task { await previous?.value; await work() }
    }
}

/// Relays raw bytes between the two sides of an upgraded connection while parsing the
/// frames it forwards. Bytes are written to the peer exactly as received.
final class WebSocketRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: Channel
    private let recorder: WebSocketRecorder
    private var parser: WebSocketFrameParser

    init(peer: Channel, direction: WebSocketMessage.Direction, recorder: WebSocketRecorder) {
        self.peer = peer
        self.recorder = recorder
        self.parser = WebSocketFrameParser(direction: direction)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        for message in parser.feed(buffer.readableBytesView) { recorder.record(message) }
        peer.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) { peer.close(promise: nil) }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        peer.close(promise: nil)
    }
}

enum WebSocketBridge {
    /// Called on the upstream channel's loop when the server answered 101. Strips the HTTP
    /// codecs from both channels, replays the 101 to the client and starts relaying frames.
    static func start(upstream context: ChannelHandlerContext, client: Channel, response: HTTPResponseRecord, flow: Flow, store: FlowStore) {
        let upstream = context.channel
        let recorder = WebSocketRecorder(store: store, flow: flow)
        let clientPipeline = client.pipeline
        let upstreamPipeline = upstream.pipeline

        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for h in response.headers { head += "\(h.name): \(h.value)\r\n" }
        head += "\r\n"

        func fail(_: Error) { client.close(promise: nil); upstream.close(promise: nil) }

        clientPipeline.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self).flatMap { clientPipeline.removeHandler($0) }
            .flatMap { clientPipeline.handler(type: HTTPResponseEncoder.self) }.flatMap { clientPipeline.removeHandler($0) }
            .flatMap { clientPipeline.handler(type: HTTPServerPipelineHandler.self) }.flatMap { clientPipeline.removeHandler($0) }
            .flatMap { clientPipeline.handler(type: ProxyFrontendHandler.self) }.flatMap { clientPipeline.removeHandler($0) }
            .flatMap { clientPipeline.addHandler(WebSocketRelayHandler(peer: upstream, direction: .sent, recorder: recorder)) }
            .flatMap { client.writeAndFlush(ByteBuffer(string: head)) }
            // Upstream: drop the HTTP handlers; bytes already buffered by the decoder flow into the relay.
            .flatMap { upstreamPipeline.addHandler(WebSocketRelayHandler(peer: client, direction: .received, recorder: recorder)) }
            .flatMap { upstreamPipeline.removeHandler(context: context) }
            .flatMap { upstreamPipeline.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self) }.flatMap { upstreamPipeline.removeHandler($0) }
            .flatMap { upstreamPipeline.handler(type: HTTPRequestEncoder.self) }.flatMap { upstreamPipeline.removeHandler($0) }
            .flatMap { upstream.setOption(ChannelOptions.autoRead, value: true) }
            .whenComplete { result in
                if case .failure(let error) = result { fail(error) } else { upstream.read() }
            }
    }
}
