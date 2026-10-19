import Foundation

/// Sends a request on its own (Repeat / Compose) and returns the exchange as a `Flow`.
/// Goes straight to the server, ignoring system proxy settings, and never follows redirects,
/// so the response recorded is exactly what the server answered.
public struct RequestSender: Sendable {
    public init() {}

    private static let managedByURLSession: Set<String> = ["host", "content-length", "connection", "proxy-connection", "transfer-encoding"]

    public func send(_ record: HTTPRequestRecord, note: String) async -> Flow {
        let started = Date()
        var request = URLRequest(url: record.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = record.method
        for h in record.headers where !Self.managedByURLSession.contains(h.name.lowercased()) {
            request.addValue(h.value, forHTTPHeaderField: h.name)
        }
        if !record.body.isEmpty { request.httpBody = record.body }

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var flow = Flow(startedAt: started, request: record, notes: [note])
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                flow.response = HTTPResponseRecord(
                    status: http.statusCode,
                    reason: HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized,
                    headers: http.allHeaderFields.compactMap { key, value in
                        (key as? String).map { HTTPHeader(name: $0, value: "\(value)") }
                    },
                    body: data
                )
            }
        } catch {
            flow.notes.append("Failed: \(error.localizedDescription)")
        }
        flow.duration = Date().timeIntervalSince(started)
        return flow
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Header blocks as editable text: one `Name: value` per line.
public enum HeaderText {
    public static func format(_ headers: [HTTPHeader]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    /// Lines without a colon or with an empty name are ignored.
    public static func parse(_ text: String) -> [HTTPHeader] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return HTTPHeader(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }
}
