import SwiftUI
import AppKit
import ProxioCore

/// Request and response side by side, each with its own tabs.
struct InspectorView: View {
    let flow: Flow

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            HSplitView {
                pane("Request") {
                    MessageView(
                        headers: flow.request.headers, payload: flow.request.decodedBody,
                        mime: header("Content-Type", in: flow.request.headers), query: queryItems,
                        raw: rawText(start: "\(flow.request.method) \(requestTarget) \(flow.request.httpVersion)", headers: flow.request.headers, body: flow.request.decodedBody),
                        messages: [], grpcPath: flow.request.url.path, isRequest: true, codeRequest: flow.request
                    )
                }
                .frame(minWidth: 280)
                pane("Response") {
                    if let r = flow.response {
                        MessageView(
                            headers: r.headers + r.trailers, payload: r.decodedBody, mime: r.mimeType, query: [],
                            raw: rawText(start: "\(r.httpVersion) \(r.status) \(r.reason)", headers: r.headers, body: r.decodedBody, trailers: r.trailers),
                            messages: flow.messages, grpcPath: flow.request.url.path, isRequest: false
                        )
                    } else {
                        ContentUnavailableView("No response yet", systemImage: "hourglass")
                    }
                }
                .frame(minWidth: 280)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(flow.request.method) \(flow.request.url.absoluteString)")
                .font(.headline).lineLimit(2).textSelection(.enabled)
            HStack(spacing: 8) {
                if let r = flow.response {
                    Text("\(r.status) \(r.reason)").foregroundStyle(r.status < 400 ? Color.proxioAccent : .red)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(BodyFormatter.byteCount(r.body.count))\(r.decodedBody.count != r.body.count ? " (\(BodyFormatter.byteCount(r.decodedBody.count)) \(String(localized: "decoded")))" : "")")
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(Int(flow.duration * 1000)) ms")
                }
                ForEach(flow.notes, id: \.self) { note in
                    Text(LocalizedStringKey(note)).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.proxioAccent.opacity(0.18), in: Capsule())
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let t = flow.timings { TimingBar(timings: t) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private func pane<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5)
                .background(.quaternary.opacity(0.5))
            content()
        }
    }

    private var requestTarget: String {
        guard let c = URLComponents(url: flow.request.url, resolvingAgainstBaseURL: false) else { return flow.request.url.path }
        return (c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath) + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    private func rawText(start: String, headers: [HTTPHeader], body: Data, trailers: [HTTPHeader] = []) -> String {
        let head = ([start] + headers.map { "\($0.name): \($0.value)" }).joined(separator: "\n")
        let tail = trailers.isEmpty ? "" : "\n\n" + trailers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        return head + "\n\n" + (String(data: body, encoding: .utf8) ?? BodyFormatter.hexDump(body)) + tail
    }

    private var queryItems: [HTTPHeader] {
        (URLComponents(url: flow.request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { HTTPHeader(name: $0.name, value: $0.value ?? "") }
    }

    private func header(_ name: String, in headers: [HTTPHeader]) -> String {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }
}

private struct MessageView: View {
    let headers: [HTTPHeader]
    let payload: Data
    let mime: String
    let query: [HTTPHeader]
    let raw: String
    let messages: [WebSocketMessage]
    var grpcPath: String? = nil
    var isRequest = false
    var codeRequest: HTTPRequestRecord? = nil
    @State private var tab: Tab = .body
    enum Tab: CaseIterable {
        case headers, query, body, raw, messages, code
        var title: LocalizedStringKey {
            switch self {
            case .headers: "Headers"
            case .query: "Query"
            case .body: "Body"
            case .raw: "Raw"
            case .messages: "Messages"
            case .code: "Code"
            }
        }
    }

    private var tabs: [Tab] {
        Tab.allCases.filter { ($0 != .query || !query.isEmpty) && ($0 != .messages || !messages.isEmpty) && ($0 != .code || codeRequest != nil) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            switch tab {
            case .headers: KeyValueTable(rows: headers)
            case .query: KeyValueTable(rows: query)
            case .body: BodyView(data: payload, mime: mime, grpcPath: grpcPath, isRequest: isRequest)
            case .raw:
                ScrollView([.horizontal, .vertical]) {
                    Text(raw).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            case .messages: WebSocketMessagesView(messages: messages)
            case .code: if let codeRequest { CodeView(request: codeRequest) }
            }
        }
    }
}

private struct KeyValueTable: View {
    let rows: [HTTPHeader]
    var body: some View {
        Table(rows.enumerated().map { Row(id: $0.offset, header: $0.element) }) {
            TableColumn("Name") { Text($0.header.name).textSelection(.enabled) }.width(min: 120, ideal: 180)
            TableColumn("Value") { Text($0.header.value).textSelection(.enabled) }
        }
    }
    private struct Row: Identifiable { let id: Int; let header: HTTPHeader }
}

private struct BodyView: View {
    let data: Data
    let mime: String
    var grpcPath: String? = nil
    var isRequest = false
    @State private var mode: Mode = .pretty
    enum Mode: CaseIterable {
        case pretty, tree, graphql, raw, hex
        var title: LocalizedStringKey {
            switch self {
            case .pretty: "Pretty"
            case .tree: "Tree"
            case .graphql: "GraphQL"
            case .raw: "Raw"
            case .hex: "Hex"
            }
        }
    }

    var body: some View {
        if data.isEmpty {
            ContentUnavailableView("Empty body", systemImage: "doc")
        } else if mime.hasPrefix("image/"), let image = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) { Image(nsImage: image).padding() }
        } else {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(modes, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: CGFloat(modes.count) * 75).padding(.bottom, 6)
                if mode == .tree, let root = tree {
                    List([root], children: \.children) { node in
                        HStack(spacing: 6) {
                            if let key = node.key { Text(key).foregroundStyle(Color.proxioAccent) }
                            Text(node.summary).foregroundStyle(node.children == nil ? .primary : .secondary).textSelection(.enabled)
                        }
                        .font(.system(.body, design: .monospaced))
                    }
                } else if mode == .graphql {
                    GraphQLView(operations: operations)
                } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(rendered)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                }
            }
        }
    }

    private var tree: JSONNode? { JSONNode.parse(data) }
    private var operations: [GraphQLOperation] { GraphQLParser.operations(in: data) }
    private var modes: [Mode] {
        Mode.allCases.filter { ($0 != .tree || tree != nil) && ($0 != .graphql || !operations.isEmpty) }
    }

    private var rendered: String {
        switch mode {
        case .tree, .graphql: BodyFormatter.prettyJSON(data) ?? String(data: data, encoding: .utf8) ?? ""
        case .pretty: BodyFormatter.prettyJSON(data) ?? BodyFormatter.prettyProtobuf(data, contentType: mime, grpcPath: grpcPath, isRequest: isRequest) ?? String(data: data, encoding: .utf8) ?? BodyFormatter.hexDump(data)
        case .raw: String(data: data, encoding: .utf8) ?? BodyFormatter.hexDump(data)
        case .hex: BodyFormatter.hexDump(data)
        }
    }
}

private struct WebSocketMessagesView: View {
    let messages: [WebSocketMessage]
    @State private var selection: UUID?

    var body: some View {
        VSplitView {
            Table(messages, selection: $selection) {
                TableColumn("") { m in
                    Image(systemName: m.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(m.direction == .sent ? Color.orange : Color.proxioAccent)
                }.width(24)
                TableColumn("Type") { Text(label(m: $0)) }.width(60)
                TableColumn("Data") { m in Text(preview(m)).lineLimit(1) }
                TableColumn("Size") { Text(BodyFormatter.byteCount($0.size)) }.width(70)
                TableColumn("Time") { Text($0.timestamp.formatted(date: .omitted, time: .standard)) }.width(80)
            }
            .frame(minHeight: 90)
            Group {
                if let m = messages.first(where: { $0.id == selection }) {
                    ScrollView {
                        Text(m.text ?? BodyFormatter.hexDump(m.payload))
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                } else {
                    ContentUnavailableView("Select a message", systemImage: "bolt.horizontal")
                }
            }
            .frame(minHeight: 60)
        }
    }

    private func label(m: WebSocketMessage) -> String {
        switch m.kind {
        case .text: String(localized: "Text")
        case .binary: String(localized: "Binary")
        case .close: String(localized: "Close")
        case .ping: "Ping"
        case .pong: "Pong"
        }
    }

    private func preview(_ m: WebSocketMessage) -> String {
        if let text = m.text { return text.replacingOccurrences(of: "\n", with: " ") }
        return "<\(BodyFormatter.byteCount(m.size))>"
    }
}

private struct GraphQLView: View {
    let operations: [GraphQLOperation]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(operations.enumerated()), id: \.offset) { _, op in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(op.name ?? String(localized: "Anonymous operation")).font(.headline)
                        Text(op.query).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        if let vars = op.variables {
                            Text("Variables").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                            Text(vars).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
    }
}

private struct CodeView: View {
    let request: HTTPRequestRecord
    @State private var language: CodeLanguage = .curl

    var body: some View {
        let code = CodeGenerator.generate(request, as: language)
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $language) {
                    ForEach(CodeLanguage.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 200)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            ScrollView([.horizontal, .vertical]) {
                Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
    }
}

/// Connect / wait / receive as proportional segments.
private struct TimingBar: View {
    let timings: FlowTimings

    var body: some View {
        let parts: [(LocalizedStringKey, TimeInterval, Color)] = [
            ("Connect", timings.connect ?? 0, .orange), ("Wait", timings.wait, Color.proxioAccent), ("Receive", timings.receive, .blue),
        ].filter { $0.1 > 0 || $0.0 == "Wait" }
        let total = max(parts.reduce(0) { $0 + $1.1 }, 0.0001)
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        p.2.frame(width: max(2, geo.size.width * p.1 / total))
                    }
                }
            }
            .frame(height: 6).clipShape(Capsule())
            HStack(spacing: 10) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 3) {
                        Circle().fill(p.2).frame(width: 6, height: 6)
                        Text(p.0); Text("\(Int(p.1 * 1000)) ms")
                    }
                }
                if timings.connect == nil { Text("Connection reused").foregroundStyle(.tertiary) }
            }
            .font(.caption2)
        }
    }
}
