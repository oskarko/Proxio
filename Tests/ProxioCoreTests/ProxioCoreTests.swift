import Testing
import Foundation
@testable import ProxioCore

private func sample(_ path: String, status: Int = 200, mime: String = "application/json") -> Flow {
    Flow(
        request: HTTPRequestRecord(method: "GET", url: URL(string: "https://api.example.com\(path)")!),
        response: HTTPResponseRecord(status: status, reason: "OK",
                                     headers: [HTTPHeader(name: "Content-Type", value: "\(mime); charset=utf-8")],
                                     body: Data("{\"ok\":true}".utf8))
    )
}

@Test func mimeTypeStripsParameters() {
    #expect(sample("/a").response?.mimeType == "application/json")
}

@Test func storeSearchMatchesUrlStatusAndMime() async {
    let store = FlowStore()
    await store.add(sample("/users"))
    await store.add(sample("/missing", status: 404, mime: "text/html"))
    #expect(await store.search("users").count == 1)
    #expect(await store.search("404").count == 1)
    #expect(await store.search("html").count == 1)
    #expect(await store.search("").count == 2)
}

@Test func storeUpdateReplacesFlow() async {
    let store = FlowStore()
    var f = sample("/a")
    await store.add(f)
    f.duration = 1.5
    await store.update(f)
    #expect(await store.all().first?.duration == 1.5)
}

@Test func harExportIsValidHAR() throws {
    let data = try HARExporter.export([sample("/users?id=7")])
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let log = try #require(root["log"] as? [String: Any])
    #expect(log["version"] as? String == "1.2")
    let entries = try #require(log["entries"] as? [[String: Any]])
    #expect(entries.count == 1)
    let req = try #require(entries[0]["request"] as? [String: Any])
    #expect((req["queryString"] as? [[String: Any]])?.first?["name"] as? String == "id")
}
