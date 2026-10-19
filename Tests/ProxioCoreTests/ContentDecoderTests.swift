import Testing
import Foundation
@testable import ProxioCore

private let plain = #"{"msg":"hello hello hello hello"}"#
private func b64(_ s: String) -> Data { Data(base64Encoded: s)! }

@Test func decodesGzipDeflateAndRawDeflate() {
    #expect(ContentDecoder.decode(b64("H4sIAAAAAAAA/6tWyi1OV7JSykjNyclXwCCVagGB68jgIQAAAA=="), encoding: "gzip").flatMap { String(data: $0, encoding: .utf8) } == plain)
    #expect(ContentDecoder.decode(b64("H4sICAAAAAAA/2EuanNvbgCrVsotTleyUspIzcnJV8AglWoBgevI4CEAAAA="), encoding: "x-gzip").flatMap { String(data: $0, encoding: .utf8) } == plain)   // with FNAME
    #expect(ContentDecoder.decode(b64("eJyrVsotTleyUspIzcnJV8AglWoBwesLsg=="), encoding: "deflate").flatMap { String(data: $0, encoding: .utf8) } == plain)   // zlib-wrapped
    #expect(ContentDecoder.decode(b64("q1bKLU5XslLKSM3JyVfAIJVqAQ=="), encoding: "deflate").flatMap { String(data: $0, encoding: .utf8) } == plain)   // raw
}

@Test func decodesBrotli() {
    #expect(ContentDecoder.decode(Data([0x0b, 0x02, 0x80, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x03]), encoding: "br").flatMap { String(data: $0, encoding: .utf8) } == "hello")
}

@Test func unknownOrCorruptEncodingsAreRejected() {
    #expect(ContentDecoder.decode(Data("x".utf8), encoding: "zstd") == nil)
    #expect(ContentDecoder.decode(Data("not gzip at all".utf8), encoding: "gzip") == nil)
    #expect(ContentDecoder.decode(Data("same".utf8), encoding: "identity") == Data("same".utf8))
}

@Test func recordsExposeDecodedBodiesAndFallBackToRaw() {
    let gz = b64("H4sIAAAAAAAA/6tWyi1OV7JSykjNyclXwCCVagGB68jgIQAAAA==")
    let response = HTTPResponseRecord(status: 200, headers: [HTTPHeader(name: "content-encoding", value: "gzip")], body: gz)
    #expect(String(data: response.decodedBody, encoding: .utf8) == plain)

    let broken = HTTPResponseRecord(status: 200, headers: [HTTPHeader(name: "Content-Encoding", value: "gzip")], body: Data("oops".utf8))
    #expect(broken.decodedBody == Data("oops".utf8))
    #expect(HTTPResponseRecord(status: 204).decodedBody.isEmpty)
}

@Test func harExportCarriesDecodedContent() throws {
    let gz = b64("H4sIAAAAAAAA/6tWyi1OV7JSykjNyclXwCCVagGB68jgIQAAAA==")
    let flow = Flow(
        request: HTTPRequestRecord(method: "GET", url: URL(string: "http://example.com/")!),
        response: HTTPResponseRecord(status: 200, headers: [HTTPHeader(name: "Content-Encoding", value: "gzip"), HTTPHeader(name: "Content-Type", value: "application/json")], body: gz)
    )
    let har = try JSONSerialization.jsonObject(with: HARExporter.export([flow])) as! [String: Any]
    let entry = ((har["log"] as! [String: Any])["entries"] as! [[String: Any]])[0]
    let content = (entry["response"] as! [String: Any])["content"] as! [String: Any]
    #expect(content["text"] as? String == plain)
    #expect(content["size"] as? Int == plain.utf8.count)
}
