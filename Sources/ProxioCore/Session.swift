import Foundation

/// A saved capture: every flow, exactly as recorded (`.proxio` files).
public struct Session: Codable, Sendable {
    public static let currentVersion = 1
    public static let fileExtension = "proxio"

    public var version: Int
    public var savedAt: Date
    public var flows: [Flow]

    public init(flows: [Flow], savedAt: Date = Date()) {
        self.version = Session.currentVersion
        self.savedAt = savedAt
        self.flows = flows
    }

    public enum LoadError: Error, LocalizedError {
        case unsupportedVersion(Int)
        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): "Session version \(v) is newer than this app understands."
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Session {
        let decoder = JSONDecoder()
        let session = try decoder.decode(Session.self, from: data)
        guard session.version <= currentVersion else { throw LoadError.unsupportedVersion(session.version) }
        return session
    }
}

/// Reads HAR 1.x files (Proxio's own, browsers', other proxies') into flows.
public enum HARImporter {
    public enum ImportError: Error, LocalizedError {
        case notHAR
        public var errorDescription: String? { "Not a HAR file." }
    }

    public static func flows(from data: Data) throws -> [Flow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = root["log"] as? [String: Any],
              let entries = log["entries"] as? [[String: Any]] else { throw ImportError.notHAR }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        func headers(_ any: Any?) -> [HTTPHeader] {
            (any as? [[String: Any]] ?? []).compactMap { h in
                guard let n = h["name"] as? String else { return nil }
                return HTTPHeader(name: n, value: h["value"] as? String ?? "")
            }
        }
        func number(_ any: Any?) -> Double { (any as? NSNumber)?.doubleValue ?? 0 }

        return entries.compactMap { e in
            guard let req = e["request"] as? [String: Any],
                  let urlString = req["url"] as? String, let url = URL(string: urlString) else { return nil }

            var reqHeaders = headers(req["headers"])
            var reqBody = Data()
            if let post = req["postData"] as? [String: Any], let text = post["text"] as? String {
                reqBody = Data(text.utf8)
                if reqHeaders.first(where: { $0.name.lowercased() == "content-type" }) == nil, let mime = post["mimeType"] as? String {
                    reqHeaders.append(HTTPHeader(name: "Content-Type", value: mime))
                }
            }
            reqHeaders.removeAll { $0.name.lowercased() == "content-encoding" }
            let request = HTTPRequestRecord(method: req["method"] as? String ?? "GET", url: url,
                                            httpVersion: req["httpVersion"] as? String ?? "HTTP/1.1",
                                            headers: reqHeaders, body: reqBody)

            var response: HTTPResponseRecord?
            if let res = e["response"] as? [String: Any], Int(number(res["status"])) > 0 {
                var resHeaders = headers(res["headers"])
                var body = Data()
                let content = res["content"] as? [String: Any] ?? [:]
                if let text = content["text"] as? String {
                    body = (content["encoding"] as? String) == "base64" ? (Data(base64Encoded: text) ?? Data()) : Data(text.utf8)
                    // HAR bodies are already decoded; keeping the header would make us decode twice.
                    resHeaders.removeAll { $0.name.lowercased() == "content-encoding" }
                    resHeaders.removeAll { $0.name.lowercased() == "content-length" }
                    resHeaders.append(HTTPHeader(name: "Content-Length", value: String(body.count)))
                }
                if resHeaders.first(where: { $0.name.lowercased() == "content-type" }) == nil, let mime = content["mimeType"] as? String, !mime.isEmpty {
                    resHeaders.append(HTTPHeader(name: "Content-Type", value: mime))
                }
                response = HTTPResponseRecord(status: Int(number(res["status"])), reason: res["statusText"] as? String ?? "",
                                              httpVersion: res["httpVersion"] as? String ?? "HTTP/1.1",
                                              headers: resHeaders, body: body)
            }

            let started = (e["startedDateTime"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) } ?? Date()
            var flow = Flow(startedAt: started, duration: max(0, number(e["time"])) / 1000, request: request, response: response)

            if let t = e["timings"] as? [String: Any], t["connect"] != nil {
                let connect = number(t["connect"])
                flow.timings = FlowTimings(connect: connect >= 0 ? connect / 1000 : nil,
                                           wait: max(0, number(t["wait"])) / 1000, receive: max(0, number(t["receive"])) / 1000)
            }

            if let frames = e["_webSocketMessages"] as? [[String: Any]] {
                flow.messages = frames.map { m in
                    let opcode = Int(number(m["opcode"]))
                    let kind: WebSocketMessage.Kind = opcode == 1 ? .text : opcode == 2 ? .binary : opcode == 8 ? .close : opcode == 9 ? .ping : .pong
                    let data = m["data"] as? String ?? ""
                    let payload = kind == .text ? Data(data.utf8) : (Data(base64Encoded: data) ?? Data(data.utf8))
                    return WebSocketMessage(timestamp: Date(timeIntervalSince1970: number(m["time"])),
                                            direction: (m["type"] as? String) == "send" ? .sent : .received,
                                            kind: kind, payload: payload)
                }
            }
            return flow
        }
    }
}
