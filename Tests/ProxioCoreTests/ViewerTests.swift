import Foundation
import Testing
@testable import ProxioCore

@Suite struct ViewerTests {
    @Test func codeGenerationCoversEveryLanguage() {
        let req = HTTPRequestRecord(method: "POST", url: URL(string: "https://api.test/v1?a=1")!,
                                    headers: [HTTPHeader(name: "Content-Type", value: "application/json")],
                                    body: Data(#"{"q":"it's \"x\""}"#.utf8))
        for language in CodeLanguage.allCases {
            let code = CodeGenerator.generate(req, as: language)
            #expect(code.contains("api.test/v1?a=1"), "\(language)")
        }
        #expect(CodeGenerator.generate(req, as: .swift).contains(#"\\\"x\\\""#))
    }

    @Test func jsonTreeAndGraphQL() throws {
        let tree = try #require(JSONNode.parse(Data(#"{"a":[1,true,null],"b":"x"}"#.utf8)))
        #expect(tree.children?.count == 2)
        #expect(tree.children?.first?.children?.map(\.summary) == ["1", "true", "null"])
        let ops = GraphQLParser.operations(in: Data(#"{"query":"query Foo { a }","variables":{"x":1}}"#.utf8))
        #expect(ops.count == 1 && ops[0].name == "Foo" && ops[0].variables != nil)
        #expect(GraphQLParser.operations(in: Data("[]".utf8)).isEmpty)
    }
}

@Suite struct TimingTests {
    @Test func timingsSurviveHARRoundTrip() throws {
        var flow = Flow(duration: 0.3, request: HTTPRequestRecord(method: "GET", url: URL(string: "https://a.test/")!),
                        response: HTTPResponseRecord(status: 200))
        flow.timings = FlowTimings(connect: 0.1, wait: 0.15, receive: 0.05)
        let back = try #require(HARImporter.flows(from: try HARExporter.export([flow])).first)
        #expect(back.timings == flow.timings)
    }
}
