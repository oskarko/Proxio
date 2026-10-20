import Testing
import Foundation
@testable import ProxioCore

@Suite struct SessionTests {
    func sample() -> [Flow] {
        let req = HTTPRequestRecord(method: "POST", url: URL(string: "https://example.com/a?x=1")!,
                                    headers: [HTTPHeader(name: "Content-Type", value: "application/json")], body: Data("{\"a\":1}".utf8))
        let res = HTTPResponseRecord(status: 200, reason: "OK", headers: [HTTPHeader(name: "Content-Type", value: "application/octet-stream")],
                                     body: Data([0xff, 0x00, 0xfe]))
        var flow = Flow(duration: 0.25, request: req, response: res)
        flow.messages = [WebSocketMessage(direction: .sent, kind: .text, payload: Data("hi".utf8))]
        return [flow, Flow(request: HTTPRequestRecord(method: "GET", url: URL(string: "http://pending.test/")!))]
    }

    @Test func sessionRoundTrips() throws {
        let flows = sample()
        let loaded = try Session.decode(Session(flows: flows).encoded())
        #expect(loaded.flows == flows)
    }

    @Test func newerSessionVersionIsRejected() throws {
        var s = Session(flows: [])
        s.version = 99
        #expect(throws: Session.LoadError.self) { try Session.decode(s.encoded()) }
    }

    @Test func harRoundTripKeepsRequestsAndBinaryBodies() throws {
        let flows = sample()
        let back = try HARImporter.flows(from: HARExporter.export(flows))
        #expect(back.count == 2)
        #expect(back[0].request.method == "POST")
        #expect(back[0].request.body == flows[0].request.body)
        #expect(back[0].response?.body == Data([0xff, 0x00, 0xfe]))
        #expect(back[0].messages.first?.text == "hi")
        #expect(back[1].response == nil)
    }

    @Test func importsBrowserStyleHAR() throws {
        let har = #"{"log":{"entries":[{"startedDateTime":"2024-01-01T10:00:00.000Z","time":120,"request":{"method":"GET","url":"https://a.test/x","headers":[]},"response":{"status":200,"statusText":"OK","headers":[{"name":"Content-Encoding","value":"gzip"}],"content":{"mimeType":"text/plain","text":"hello"}}}]}}"#
        let flows = try HARImporter.flows(from: Data(har.utf8))
        #expect(flows[0].response?.decodedBody == Data("hello".utf8))
        #expect(abs(flows[0].duration - 0.12) < 0.001)
        #expect(throws: HARImporter.ImportError.self) { try HARImporter.flows(from: Data("{}".utf8)) }
    }
}
