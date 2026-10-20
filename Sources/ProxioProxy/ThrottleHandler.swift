import Foundation
import NIOCore
import ProxioCore

/// Sits first in a client connection's pipeline and delays and paces the raw bytes in both
/// directions according to the live `NetworkProfile`. Order is always preserved; with a
/// transparent profile and nothing queued it is a plain pass-through.
final class ThrottleHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = IOData
    typealias OutboundOut = IOData

    private struct Lane {
        var nextFree = NIODeadline.now()
        var lastRelease = NIODeadline.now()
        var pending = 0

        /// When a chunk of `size` bytes becomes visible on the far side.
        mutating func schedule(size: Int, bytesPerSecond: Double?, delay: TimeAmount) -> NIODeadline {
            let now = NIODeadline.now()
            let start = max(now, nextFree)
            let transmit = bytesPerSecond.map { TimeAmount.nanoseconds(Int64(Double(size) / $0 * 1_000_000_000)) } ?? .nanoseconds(0)
            nextFree = start + transmit
            lastRelease = max(start + transmit + delay, lastRelease)
            return lastRelease
        }

        func idle(_ now: NIODeadline) -> Bool { pending == 0 && lastRelease <= now }
    }

    private let conditions: NetworkConditions
    private var inbound = Lane()
    private var outbound = Lane()

    init(conditions: NetworkConditions) { self.conditions = conditions }

    func channelActive(context: ChannelHandlerContext) {
        if conditions.profile.offline { context.close(promise: nil); return }
        context.fireChannelActive()
    }

    // MARK: client → proxy (upload)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let profile = conditions.profile
        if profile.offline { context.close(promise: nil); return }
        let buffer = unwrapInboundIn(data)
        if profile.isTransparent, inbound.idle(.now()) {
            context.fireChannelRead(data)
            return
        }
        let at = inbound.schedule(size: buffer.readableBytes, bytesPerSecond: profile.bytesPerSecond(download: false),
                                  delay: .milliseconds(Int64(max(0, profile.latencyMs) / 2)))
        inbound.pending += 1
        context.eventLoop.scheduleTask(deadline: at) {
            self.inbound.pending -= 1
            context.fireChannelRead(NIOAny(buffer))
            context.fireChannelReadComplete()
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if inbound.pending == 0 { context.fireChannelReadComplete() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let now = NIODeadline.now()
        if inbound.idle(now) {
            context.fireChannelInactive()
        } else {
            context.eventLoop.scheduleTask(deadline: max(inbound.lastRelease, now)) { context.fireChannelInactive() }
        }
    }

    // MARK: proxy → client (download)

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let profile = conditions.profile
        guard case .byteBuffer(let buffer) = unwrapOutboundIn(data) else {
            context.write(data, promise: promise)
            return
        }
        if profile.isTransparent, outbound.idle(.now()) {
            context.write(data, promise: promise)
            return
        }
        let at = outbound.schedule(size: buffer.readableBytes, bytesPerSecond: profile.bytesPerSecond(download: true),
                                   delay: .milliseconds(Int64(max(0, profile.latencyMs) / 2)))
        outbound.pending += 1
        context.eventLoop.scheduleTask(deadline: at) {
            self.outbound.pending -= 1
            context.writeAndFlush(NIOAny(IOData.byteBuffer(buffer)), promise: promise)
        }
    }

    func flush(context: ChannelHandlerContext) {
        // Queued writes flush themselves when released.
        if outbound.pending == 0 { context.flush() }
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        let now = NIODeadline.now()
        if outbound.idle(now) {
            context.close(mode: mode, promise: promise)
        } else {
            context.eventLoop.scheduleTask(deadline: max(outbound.lastRelease, now)) { context.close(mode: mode, promise: promise) }
        }
    }
}
