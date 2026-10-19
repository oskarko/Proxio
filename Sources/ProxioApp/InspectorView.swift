import SwiftUI
import AppKit
import ProxioCore

struct InspectorView: View {
    let flow: Flow
    @State private var side: Side = .response
    enum Side: String, CaseIterable { case request = "Request", response = "Response" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(flow.request.method) \(flow.request.url.absoluteString)")
                    .font(.headline).lineLimit(2).textSelection(.enabled)
                if let r = flow.response {
                    Text("\(r.status) \(r.reason) · \(BodyFormatter.byteCount(r.body.count)) · \(Int(flow.duration * 1000)) ms")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)

            Picker("", selection: $side) {
                ForEach(Side.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.bottom, 8)

            Divider()
            switch side {
            case .request:
                MessageView(headers: flow.request.headers, payload: flow.request.body, mime: header("Content-Type", in: flow.request.headers), query: queryItems)
            case .response:
                if let r = flow.response {
                    MessageView(headers: r.headers, payload: r.body, mime: r.mimeType, query: [])
                } else {
                    ContentUnavailableView("No response yet", systemImage: "hourglass")
                }
            }
        }
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
    @State private var tab: Tab = .body
    enum Tab: String, CaseIterable { case headers = "Headers", query = "Query", body = "Body" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases.filter { $0 != .query || !query.isEmpty }, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            switch tab {
            case .headers: KeyValueTable(rows: headers)
            case .query: KeyValueTable(rows: query)
            case .body: BodyView(data: payload, mime: mime)
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
    @State private var mode: Mode = .pretty
    enum Mode: String, CaseIterable { case pretty = "Pretty", raw = "Raw", hex = "Hex" }

    var body: some View {
        if data.isEmpty {
            ContentUnavailableView("Empty body", systemImage: "doc")
        } else if mime.hasPrefix("image/"), let image = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) { Image(nsImage: image).padding() }
        } else {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220).padding(.bottom, 6)
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

    private var rendered: String {
        switch mode {
        case .pretty: BodyFormatter.prettyJSON(data) ?? String(data: data, encoding: .utf8) ?? BodyFormatter.hexDump(data)
        case .raw: String(data: data, encoding: .utf8) ?? BodyFormatter.hexDump(data)
        case .hex: BodyFormatter.hexDump(data)
        }
    }
}
