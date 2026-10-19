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

@Suite struct ProtoSchemaTests {
    static let source = """
    syntax = "proto3";
    package demo.v1;
    // comment
    enum Color { RED = 0; GREEN = 1; }
    message Point { sint32 x = 1; double y = 2; }
    message Req {
      string name = 1;
      int32 delta = 2;
      Color color = 3;
      repeated int32 ids = 4;
      Point at = 5;
      map<string, int32> scores = 6;
      oneof pick { bool flag = 7; }
      message Inner { string v = 1; }
      Inner inner = 8;
    }
    service Greeter { rpc Hello (Req) returns (stream Point); }
    """

    @Test func parsesAndNamesFields() throws {
        var schema = ProtoSchema()
        let parsed = schema.add(source: Self.source)
        #expect(parsed)
        #expect(schema.methods["/demo.v1.Greeter/Hello"] == .init(input: "demo.v1.Req", output: "demo.v1.Point"))
        var d = Data([0x0a, 2, 0x61, 0x62, 0x10])
        d.append(contentsOf: [UInt8](repeating: 0xff, count: 9) + [0x01])
        d.append(contentsOf: [0x18, 0x01, 0x22, 0x02, 0x01, 0x02, 0x2a, 0x02, 0x08, 0x03, 0x38, 0x01, 0x42, 0x03, 0x0a, 0x01, 0x7a])
        let text = try #require(schema.render(d, as: "demo.v1.Req"))
        #expect(text == """
        name: "ab"
        delta: -1
        color: GREEN
        ids: 1
        ids: 2
        at {
          x: -2
        }
        flag: true
        inner {
          v: "z"
        }
        """)
    }

    @Test func unknownFieldsFallBackToRaw() throws {
        var schema = ProtoSchema()
        schema.add(source: Self.source)
        let text = try #require(schema.render(Data([0x58, 0x05]), as: "demo.v1.Req"))
        #expect(text == "11: 5")
    }

    @Test func grpcBodyUsesMethodTypes() throws {
        var schema = ProtoSchema()
        schema.add(source: Self.source)
        var body = Data([0, 0, 0, 0, 3]); body.append(contentsOf: [0x0a, 0x01, 0x78])
        let text = try #require(GRPC.render(body, contentType: "application/grpc", messageType: "demo.v1.Req", schema: schema))
        #expect(text == "# message 1\nname: \"x\"")
    }
}
