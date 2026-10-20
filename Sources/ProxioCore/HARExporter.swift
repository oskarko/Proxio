import Foundation

/// Serialises flows to HAR 1.2 (http://www.softwareishard.com/blog/har-12-spec/).
public enum HARExporter {
    public static func export(_ flows: [Flow]) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func headers(_ h: [HTTPHeader]) -> [[String: Any]] {
            h.map { ["name": $0.name, "value": $0.value] }
        }

        let entries: [[String: Any]] = flows.map { f in
            let res = f.response
            let decoded = res?.decodedBody ?? Data()
            let bodyText = String(data: decoded, encoding: .utf8)
            var content: [String: Any] = ["size": decoded.count, "mimeType": res?.mimeType ?? "", "text": bodyText ?? decoded.base64EncodedString()]
            if bodyText == nil { content["encoding"] = "base64" }
            var entry: [String: Any] = [
                "startedDateTime": iso.string(from: f.startedAt),
                "time": f.duration * 1000,
                "request": [
                    "method": f.request.method,
                    "url": f.request.url.absoluteString,
                    "httpVersion": f.request.httpVersion,
                    "headers": headers(f.request.headers),
                    "queryString": (URLComponents(url: f.request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ["name": $0.name, "value": $0.value ?? ""] },
                    "cookies": [] as [Any],
                    "headersSize": -1,
                    "bodySize": f.request.body.count,
                ] as [String: Any],
                "response": [
                    "status": res?.status ?? 0,
                    "statusText": res?.reason ?? "",
                    "httpVersion": res?.httpVersion ?? "HTTP/1.1",
                    "headers": headers(res?.headers ?? []),
                    "cookies": [] as [Any],
                    "content": content,
                    "redirectURL": "",
                    "headersSize": -1,
                    "bodySize": res?.body.count ?? 0,
                ] as [String: Any],
                "cache": [String: Any](),
                "timings": ["send": 0, "wait": f.duration * 1000, "receive": 0],
            ]
            if !f.request.body.isEmpty, var req = entry["request"] as? [String: Any] {
                let mime = f.request.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? ""
                req["postData"] = ["mimeType": mime, "text": String(decoding: f.request.decodedBody, as: UTF8.self)] as [String: Any]
                entry["request"] = req
            }
            return entry.merging(f.messages.isEmpty ? [:] : ["_webSocketMessages": f.messages.map { m -> [String: Any] in
                [
                    "type": m.direction == .sent ? "send" : "receive",
                    "time": m.timestamp.timeIntervalSince1970,
                    "opcode": m.kind == .text ? 1 : m.kind == .binary ? 2 : m.kind == .close ? 8 : m.kind == .ping ? 9 : 10,
                    "data": m.text ?? m.payload.base64EncodedString(),
                ]
            }] as [String: Any]) { $1 }
        }

        let har: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": ["name": "Proxio", "version": "0.1.0"],
                "entries": entries,
            ] as [String: Any],
        ]
        return try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .sortedKeys])
    }
}
