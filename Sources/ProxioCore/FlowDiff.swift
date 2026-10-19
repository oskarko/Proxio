import Foundation

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable { case same, removed, added }
    public var kind: Kind
    public var text: String
    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum TextDiff {
    /// Bodies beyond this many lines are compared up to the limit only.
    public static let lineLimit = 20_000

    /// Line diff: `removed` lines exist only in `a`, `added` only in `b`.
    public static func lines(_ a: [String], _ b: [String]) -> [DiffLine] {
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { out.append(DiffLine(.removed, a[i])); i += 1 }
            else if j < b.count, inserted.contains(j) { out.append(DiffLine(.added, b[j])); j += 1 }
            else { out.append(DiffLine(.same, a[i])); i += 1; j += 1 }
        }
        return out
    }

    public static func lines(_ a: String, _ b: String) -> [DiffLine] {
        func split(_ s: String) -> [String] { s.isEmpty ? [] : Array(s.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineLimit).map(String.init)) }
        return lines(split(a), split(b))
    }
}

/// Differences between one part of two messages.
public struct MessageDiff: Sendable, Equatable {
    public var startLine: [DiffLine]
    public var headers: [DiffLine]
    public var body: [DiffLine]
    public var isIdentical: Bool {
        (startLine + headers + body).allSatisfy { $0.kind == .same }
    }
}

public struct FlowDiff: Sendable, Equatable {
    public var request: MessageDiff
    /// nil when neither flow has a response.
    public var response: MessageDiff?

    public static func compare(_ a: Flow, _ b: Flow) -> FlowDiff {
        let request = message(
            startA: "\(a.request.method) \(a.request.url.absoluteString)", startB: "\(b.request.method) \(b.request.url.absoluteString)",
            headersA: a.request.headers, headersB: b.request.headers,
            bodyA: a.request.decodedBody, bodyB: b.request.decodedBody
        )
        let response: MessageDiff?
        if a.response == nil, b.response == nil {
            response = nil
        } else {
            func start(_ r: HTTPResponseRecord?) -> String { r.map { "\($0.status) \($0.reason)" } ?? "(no response)" }
            response = message(
                startA: start(a.response), startB: start(b.response),
                headersA: a.response?.headers ?? [], headersB: b.response?.headers ?? [],
                bodyA: a.response?.decodedBody ?? Data(), bodyB: b.response?.decodedBody ?? Data()
            )
        }
        return FlowDiff(request: request, response: response)
    }

    private static func message(startA: String, startB: String, headersA: [HTTPHeader], headersB: [HTTPHeader], bodyA: Data, bodyB: Data) -> MessageDiff {
        MessageDiff(
            startLine: TextDiff.lines([startA], [startB]),
            headers: TextDiff.lines(normalized(headersA), normalized(headersB)),
            body: TextDiff.lines(text(bodyA), text(bodyB))
        )
    }

    /// Header order is irrelevant and names are case-insensitive, so sort by lowercased name.
    private static func normalized(_ headers: [HTTPHeader]) -> [String] {
        headers.map { "\($0.name.lowercased()): \($0.value)" }.sorted()
    }

    private static func text(_ data: Data) -> String {
        if data.isEmpty { return "" }
        if let json = BodyFormatter.prettyJSON(data) { return json }
        if let text = String(data: data, encoding: .utf8) { return text }
        // djb2 so equal binary bodies compare equal and different ones almost surely do not.
        let hash = data.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1) }
        return "<binary body, \(data.count) bytes, checksum \(String(hash, radix: 16))>"
    }
}
