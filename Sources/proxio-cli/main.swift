import Foundation
import ProxioCore
import ProxioProxy

setlinebuf(stdout)
let port = CommandLine.arguments.dropFirst().first.flatMap { Int($0) } ?? 9090
let store = FlowStore()
let server = ProxyServer(store: store, port: port)
let bound = try await server.start()
print("Proxio listening on 127.0.0.1:\(bound)")

var printed = 0
while true {
    try await Task.sleep(nanoseconds: 500_000_000)
    let flows = await store.all()
    for f in flows.dropFirst(printed) {
        print("\(f.request.method) \(f.request.url.absoluteString) -> \(f.response?.status ?? 0)")
    }
    printed = flows.count
}
