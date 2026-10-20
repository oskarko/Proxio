import Foundation

public struct HTTPHeader: Sendable, Hashable, Codable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct HTTPRequestRecord: Sendable, Equatable, Codable {
    public var method: String
    public var url: URL
    public var httpVersion: String
    public var headers: [HTTPHeader]
    public var body: Data

    public init(method: String, url: URL, httpVersion: String = "HTTP/1.1", headers: [HTTPHeader] = [], body: Data = Data()) {
        self.method = method
        self.url = url
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponseRecord: Sendable, Equatable, Codable {
    public var status: Int
    public var reason: String
    public var httpVersion: String
    public var headers: [HTTPHeader]
    public var body: Data
    /// Headers sent after the body (HTTP/2 trailers, e.g. gRPC's `grpc-status`).
    public var trailers: [HTTPHeader]

    public init(status: Int, reason: String = "", httpVersion: String = "HTTP/1.1", headers: [HTTPHeader] = [], body: Data = Data(), trailers: [HTTPHeader] = []) {
        self.status = status
        self.reason = reason
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.trailers = trailers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(Int.self, forKey: .status)
        reason = try c.decode(String.self, forKey: .reason)
        httpVersion = try c.decode(String.self, forKey: .httpVersion)
        headers = try c.decode([HTTPHeader].self, forKey: .headers)
        body = try c.decode(Data.self, forKey: .body)
        trailers = try c.decodeIfPresent([HTTPHeader].self, forKey: .trailers) ?? []
    }

    public var mimeType: String {
        headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?
            .value.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// One captured request/response exchange.
/// Where a request spent its time. `connect` is nil when a pooled connection was reused.
public struct FlowTimings: Sendable, Equatable, Codable {
    public var connect: TimeInterval?
    /// From sending the request to the first response byte.
    public var wait: TimeInterval
    /// From the first response byte to the last.
    public var receive: TimeInterval

    public init(connect: TimeInterval? = nil, wait: TimeInterval, receive: TimeInterval) {
        self.connect = connect
        self.wait = wait
        self.receive = receive
    }
}

public struct Flow: Sendable, Identifiable, Equatable, Codable {
    public let id: UUID
    public var startedAt: Date
    public var duration: TimeInterval
    public var request: HTTPRequestRecord
    public var response: HTTPResponseRecord?
    /// Rules that altered this exchange, e.g. "Map Local".
    public var notes: [String]
    /// Frames seen after a WebSocket upgrade (101), oldest first.
    public var messages: [WebSocketMessage]
    public var timings: FlowTimings?

    public var isWebSocket: Bool {
        response?.status == 101
            && request.headers.contains { $0.name.caseInsensitiveCompare("Upgrade") == .orderedSame && $0.value.lowercased() == "websocket" }
    }

    public init(id: UUID = UUID(), startedAt: Date = Date(), duration: TimeInterval = 0, request: HTTPRequestRecord, response: HTTPResponseRecord? = nil, notes: [String] = [], messages: [WebSocketMessage] = [], timings: FlowTimings? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.request = request
        self.response = response
        self.notes = notes
        self.messages = messages
        self.timings = timings
    }
}
