import Foundation

/// Turns a captured request into a snippet for a given language or tool.
public enum CodeLanguage: String, CaseIterable, Sendable, Identifiable {
    case curl = "cURL"
    case swift = "Swift (URLSession)"
    case python = "Python (requests)"
    case javascript = "JavaScript (fetch)"
    case kotlin = "Kotlin (OkHttp)"
    case httpie = "HTTPie"

    public var id: String { rawValue }
}

public enum CodeGenerator {
    public static func generate(_ request: HTTPRequestRecord, as language: CodeLanguage) -> String {
        let headers = request.headers.filter { !["content-length", "host", "connection"].contains($0.name.lowercased()) }
        let text = request.body.isEmpty ? nil : String(data: request.body, encoding: .utf8)
        let url = request.url.absoluteString
        switch language {
        case .curl:
            return CURLExporter.command(for: request)
        case .swift:
            var s = "var request = URLRequest(url: URL(string: \(lit(url)))!)\nrequest.httpMethod = \(lit(request.method))\n"
            for h in headers { s += "request.setValue(\(lit(h.value)), forHTTPHeaderField: \(lit(h.name)))\n" }
            if let text { s += "request.httpBody = \(lit(text)).data(using: .utf8)\n" }
            s += "\nlet (data, response) = try await URLSession.shared.data(for: request)\n"
            return s
        case .python:
            var s = "import requests\n\n"
            s += "headers = {\n" + headers.map { "    \(lit($0.name)): \(lit($0.value))," }.joined(separator: "\n") + "\n}\n"
            s += "response = requests.request(\(lit(request.method)), \(lit(url)), headers=headers"
            if let text { s += ", data=\(lit(text))" }
            s += ")\nprint(response.status_code, response.text)\n"
            return s
        case .javascript:
            var s = "const response = await fetch(\(lit(url)), {\n  method: \(lit(request.method)),\n  headers: {\n"
            s += headers.map { "    \(lit($0.name)): \(lit($0.value))," }.joined(separator: "\n") + "\n  }"
            if let text { s += ",\n  body: \(lit(text))" }
            s += "\n});\nconsole.log(response.status, await response.text());\n"
            return s
        case .kotlin:
            var s = "val client = OkHttpClient()\nval request = Request.Builder()\n    .url(\(lit(url)))\n"
            for h in headers { s += "    .header(\(lit(h.name)), \(lit(h.value)))\n" }
            if let text {
                let type = request.headers.first { $0.name.lowercased() == "content-type" }?.value ?? "text/plain"
                s += "    .method(\(lit(request.method)), \(lit(text)).toRequestBody(\(lit(type)).toMediaType()))\n"
            } else {
                s += "    .method(\(lit(request.method)), \(["POST", "PUT", "PATCH"].contains(request.method.uppercased()) ? "ByteArray(0).toRequestBody()" : "null"))\n"
            }
            s += "    .build()\nclient.newCall(request).execute().use { println(it.body?.string()) }\n"
            return s
        case .httpie:
            var parts = ["http", request.method, CURLExporter.quote(url)]
            for h in headers { parts.append(CURLExporter.quote("\(h.name):\(h.value)")) }
            let head = parts.joined(separator: " ")
            if let text { return "printf %s \(CURLExporter.quote(text)) | \(head)" }
            return head
        }
    }

    /// Double-quoted string literal valid in Swift, Python, JavaScript and Kotlin.
    static func lit(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "$": out += "$"
            default:
                if u.value < 0x20 { out += String(format: "\\u{%x}", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
