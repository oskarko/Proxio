import Testing
import Foundation
@testable import ProxioCore

@Suite struct ProtobufTests {
    // message { 1: 150, 2: "hi", 3 { 1: 7 } }
    static let sample = Data([0x08, 0x96, 0x01, 0x12, 0x02, 0x68, 0x69, 0x1a, 0x02, 0x08, 0x07])

    @Test func decodesVarintStringAndNestedMessage() throws {
        let fields = try #require(ProtobufDecoder.decode(Self.sample))
        #expect(fields.count == 3)
        #expect(fields[0] == ProtoField(number: 1, value: .varint(150)))
        #expect(ProtobufDecoder.render(fields) == "1: 150\n2: \"hi\"\n3 {\n  1: 7\n}")
    }

    @Test func decodesFixedWidthFields() throws {
        let d = Data([0x0d, 1, 0, 0, 0, 0x11, 2, 0, 0, 0, 0, 0, 0, 0])
        let f = try #require(ProtobufDecoder.decode(d))
        #expect(f == [ProtoField(number: 1, value: .fixed32(1)), ProtoField(number: 2, value: .fixed64(2))])
    }

    @Test func rejectsMalformedInput() {
        #expect(ProtobufDecoder.decode(Data([0x12, 0x05, 0x61])) == nil)   // length past the end
        #expect(ProtobufDecoder.decode(Data([0x0b])) == nil)               // start-group wire type
        #expect(ProtobufDecoder.decode(Data([0x00])) == nil)               // field number 0
        #expect(ProtobufDecoder.decode(Data()) == nil)
    }

    @Test func splitsGRPCFramesAndTrailers() throws {
        var body = Data([0, 0, 0, 0, UInt8(Self.sample.count)]) + Self.sample
        let trailers = Data("grpc-status: 0\r\n".utf8)
        body += Data([0x80, 0, 0, 0, UInt8(trailers.count)]) + trailers
        let frames = try #require(GRPC.frames(from: body))
        #expect(frames.count == 2)
        #expect(frames[1].isTrailers)
        let text = try #require(GRPC.render(body, contentType: "application/grpc+proto"))
        #expect(text.contains("# message 1"))
        #expect(text.contains("1: 150"))
        #expect(text.contains("grpc-status: 0"))
    }

    @Test func grpcWebTextIsBase64() throws {
        let body = Data([0, 0, 0, 0, UInt8(Self.sample.count)]) + Self.sample
        let text = try #require(GRPC.render(Data(body.base64EncodedString().utf8), contentType: "application/grpc-web-text"))
        #expect(text.contains("2: \"hi\""))
    }

    @Test func brokenFramingReturnsNil() {
        #expect(GRPC.frames(from: Data([0, 0, 0, 0, 9, 1])) == nil)
        #expect(BodyFormatter.prettyProtobuf(Data([1, 2]), contentType: "application/json") == nil)
    }
}
