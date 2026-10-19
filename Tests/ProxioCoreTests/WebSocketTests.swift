import Testing
import Foundation
import ProxioCore

@Test func parsesMaskedAndUnmaskedFramesSplitAcrossReads() {
    var parser = WebSocketFrameParser(direction: .sent)
    let masked = WebSocketFrame.encode(opcode: 1, payload: Data("hello".utf8), maskKey: [1, 2, 3, 4])
    #expect(masked.count == 11)
    #expect(parser.feed(masked.prefix(3)).isEmpty)
    let messages = parser.feed(masked.dropFirst(3))
    #expect(messages.count == 1)
    #expect(messages[0].kind == .text)
    #expect(messages[0].text == "hello")
    #expect(messages[0].direction == .sent)

    var server = WebSocketFrameParser(direction: .received)
    let two = WebSocketFrame.encode(opcode: 2, payload: Data([1, 2, 3])) + WebSocketFrame.encode(opcode: 9, payload: Data())
    let parsed = server.feed(two)
    #expect(parsed.map(\.kind) == [.binary, .ping])
    #expect(parsed[0].text == nil)
}

@Test func reassemblesFragmentsAndHandlesLongFramesAndClose() {
    var parser = WebSocketFrameParser(direction: .received)
    var first = WebSocketFrame.encode(opcode: 1, payload: Data("Hel".utf8)); first[0] &= 0x7F   // FIN off
    let ping = WebSocketFrame.encode(opcode: 9, payload: Data("p".utf8))                    // control frame in between
    let last = WebSocketFrame.encode(opcode: 0, payload: Data("lo".utf8))
    let messages = parser.feed(first + ping + last)
    #expect(messages.map(\.kind) == [.ping, .text])
    #expect(messages[1].text == "Hello")

    let big = Data(repeating: 0x61, count: 70_000)
    let long = parser.feed(WebSocketFrame.encode(opcode: 2, payload: big, maskKey: [9, 8, 7, 6]))
    #expect(long.first?.size == 70_000)
    #expect(long.first?.payload == big)

    let close = parser.feed(WebSocketFrame.encode(opcode: 8, payload: Data([0x03, 0xE8]) + Data("bye".utf8)))
    #expect(close.first?.kind == .close)
    #expect(close.first?.text == "1000 bye")
}

@Test func storeAppendsMessagesToAFlow() async throws {
    let store = FlowStore()
    let flow = Flow(request: HTTPRequestRecord(method: "GET", url: URL(string: "http://x/ws")!, headers: [HTTPHeader(name: "Upgrade", value: "websocket")]),
                    response: HTTPResponseRecord(status: 101))
    await store.add(flow)
    await store.append(WebSocketMessage(direction: .sent, kind: .text, payload: Data("a".utf8)), to: flow.id)
    let stored = try #require(await store.all().first)
    #expect(stored.isWebSocket)
    #expect(stored.messages.count == 1)
}
