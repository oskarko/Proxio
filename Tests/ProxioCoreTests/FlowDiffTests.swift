import Testing
import Foundation
@testable import ProxioCore

@Test func textDiffMarksRemovedAndAddedLines() {
    let diff = TextDiff.lines("a\nb\nc\nd", "a\nB\nc\nd\ne")
    #expect(diff == [
        DiffLine(.same, "a"), DiffLine(.removed, "b"), DiffLine(.added, "B"),
        DiffLine(.same, "c"), DiffLine(.same, "d"), DiffLine(.added, "e"),
    ])
    #expect(TextDiff.lines("", "x") == [DiffLine(.added, "x")])
    #expect(TextDiff.lines("x", "") == [DiffLine(.removed, "x")])
    #expect(TextDiff.lines("", "").isEmpty)
}

@Test func textDiffReconstructsBothSides() {
    let a = (0..<200).map { "line \($0 % 17)" }, b = (0..<210).map { "line \($0 % 13)" }
    let diff = TextDiff.lines(a, b)
    #expect(diff.filter { $0.kind != .added }.map(\.text) == a)
    #expect(diff.filter { $0.kind != .removed }.map(\.text) == b)
}

private func flow(_ method: String = "GET", _ url: String = "http://x.com/a", status: Int? = 200, headers: [HTTPHeader] = [], body: String = "") -> Flow {
    Flow(
        request: HTTPRequestRecord(method: method, url: URL(string: url)!),
        response: status.map { HTTPResponseRecord(status: $0, reason: "R", headers: headers, body: Data(body.utf8)) }
    )
}

@Test func identicalFlowsHaveNoDifferences() {
    let a = flow(headers: [HTTPHeader(name: "A", value: "1"), HTTPHeader(name: "B", value: "2")], body: #"{"x":1,"y":2}"#)
    let b = flow(headers: [HTTPHeader(name: "b", value: "2"), HTTPHeader(name: "a", value: "1")], body: #"{ "y": 2, "x": 1 }"#)
    let diff = FlowDiff.compare(a, b)
    #expect(diff.request.isIdentical)
    #expect(diff.response?.isIdentical == true)   // header order/case and JSON formatting are not differences
}

@Test func reportsChangedStatusHeadersAndJSONBody() throws {
    let a = flow(status: 200, headers: [HTTPHeader(name: "X-V", value: "1")], body: #"{"user":"ann","age":30}"#)
    let b = flow(status: 500, headers: [HTTPHeader(name: "X-V", value: "2")], body: #"{"user":"ann","age":31}"#)
    let response = try #require(FlowDiff.compare(a, b).response)
    #expect(response.startLine == [DiffLine(.removed, "200 R"), DiffLine(.added, "500 R")])
    #expect(response.headers == [DiffLine(.removed, "x-v: 1"), DiffLine(.added, "x-v: 2")])
    #expect(response.body.contains(DiffLine(.removed, #"  "age" : 30,"#)) || response.body.contains { $0.kind == .removed && $0.text.contains("30") })
    #expect(response.body.contains { $0.kind == .added && $0.text.contains("31") })
    #expect(response.body.contains { $0.kind == .same && $0.text.contains("ann") })
}

@Test func missingResponsesAndBinaryBodiesAreHandled() throws {
    #expect(FlowDiff.compare(flow(status: nil), flow(status: nil)).response == nil)
    let onlyB = try #require(FlowDiff.compare(flow(status: nil), flow(status: 204)).response)
    #expect(onlyB.startLine.first == DiffLine(.removed, "(no response)"))

    func binary(_ bytes: [UInt8]) -> Flow {
        Flow(request: HTTPRequestRecord(method: "GET", url: URL(string: "http://x.com/")!),
             response: HTTPResponseRecord(status: 200, body: Data(bytes)))
    }
    #expect(FlowDiff.compare(binary([0xff, 0xfe, 1]), binary([0xff, 0xfe, 1])).response?.isIdentical == true)
    #expect(FlowDiff.compare(binary([0xff, 0xfe, 1]), binary([0xff, 0xfe, 2])).response?.isIdentical == false)
}
