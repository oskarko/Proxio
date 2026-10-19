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

    public init(status: Int, reason: String = "", httpVersion: String = "HTTP/1.1", headers: [HTTPHeader] = [], body: Data = Data()) {
        self.status = status
        self.reason = reason
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
    }

    public var mimeType: String {
        headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?
            .value.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// One captured request/response exchange.
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

    public var isWebSocket: Bool {
        response?.status == 101
            && request.headers.contains { $0.name.caseInsensitiveCompare("Upgrade") == .orderedSame && $0.value.lowercased() == "websocket" }
    }

    public init(id: UUID = UUID(), startedAt: Date = Date(), duration: TimeInterval = 0, request: HTTPRequestRecord, response: HTTPResponseRecord? = nil, notes: [String] = [], messages: [WebSocketMessage] = []) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.request = request
        self.response = response
        self.notes = notes
        self.messages = messages
    }
}
