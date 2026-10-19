import SwiftUI
import AppKit
import ProxioCore

extension Binding where Value == String? {
    /// Edits an optional string as text; empty means nil.
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

extension AppModel {
    /// Pre-fills a Map Local rule with the exact response seen in `flow`.
    func mapLocal(from flow: Flow) {
        guard let response = flow.response else { return }
        let url = flow.request.url
        let pattern = (url.host ?? "*") + (url.port.map { ":\($0)" } ?? "") + (url.path.isEmpty ? "/" : url.path)
        let skipped: Set<String> = ["content-length", "transfer-encoding", "connection", "content-encoding"]
        mapLocalRules.append(MapLocalRule(
            matcher: RequestMatcher(method: flow.request.method, urlPattern: pattern),
            status: response.status,
            headers: response.headers.filter { !skipped.contains($0.name.lowercased()) },
            body: response.body
        ))
    }
}

struct MapRulesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var selectedLocal: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Map Local").tag(0)
                Text("Map Remote").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            Text(tab == 0
                 ? "Answer matching requests with a file or text, without contacting the server."
                 : "Send matching requests to a different scheme, host, port or path. Empty fields keep the original.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if tab == 0 { local } else { remote }
            Divider()
            HStack {
                Button("Add") {
                    if tab == 0 {
                        let rule = MapLocalRule(matcher: RequestMatcher(urlPattern: "example.com/*"))
                        model.mapLocalRules.append(rule)
                        selectedLocal = rule.id
                    } else {
                        model.mapRemoteRules.append(MapRemoteRule(matcher: RequestMatcher(urlPattern: "example.com/*")))
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 760, height: 520)
    }

    private var local: some View {
        HSplitView {
            List(selection: $selectedLocal) {
                ForEach($model.mapLocalRules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.isEnabled).labelsHidden()
                        VStack(alignment: .leading) {
                            Text(rule.matcher.urlPattern.isEmpty ? "(any)" : rule.matcher.urlPattern).lineLimit(1)
                            Text("\(rule.status) · \(rule.filePath.map { ($0 as NSString).lastPathComponent } ?? "inline")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(rule.id)
                }
                .onDelete { model.mapLocalRules.remove(atOffsets: $0) }
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
            .overlay { if model.mapLocalRules.isEmpty { ContentUnavailableView("No Map Local rules", systemImage: "doc.badge.gearshape") } }

            if let index = model.mapLocalRules.firstIndex(where: { $0.id == selectedLocal }) {
                MapLocalEditor(rule: $model.mapLocalRules[index]).id(model.mapLocalRules[index].id)
            } else {
                ContentUnavailableView("Select a rule", systemImage: "sidebar.left").frame(maxWidth: .infinity)
            }
        }
    }

    private var remote: some View {
        List {
            ForEach($model.mapRemoteRules) { $rule in
                HStack(spacing: 6) {
                    Toggle("", isOn: $rule.isEnabled).labelsHidden()
                    TextField("host/path pattern", text: $rule.matcher.urlPattern)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("scheme", text: $rule.scheme.orEmpty).frame(width: 60)
                    TextField("host", text: $rule.host.orEmpty)
                    TextField("port", value: $rule.port, format: .number.grouping(.never)).frame(width: 60)
                    TextField("path", text: $rule.path.orEmpty).frame(width: 100)
                }
                .textFieldStyle(.roundedBorder)
            }
            .onDelete { model.mapRemoteRules.remove(atOffsets: $0) }
        }
        .overlay { if model.mapRemoteRules.isEmpty { ContentUnavailableView("No Map Remote rules", systemImage: "arrow.triangle.branch") } }
    }
}

private struct MapLocalEditor: View {
    @Binding var rule: MapLocalRule
    @State private var headersText = ""
    @State private var useFile = false

    var body: some View {
        Form {
            HStack {
                Picker("Method", selection: Binding(get: { rule.matcher.method ?? "" }, set: { rule.matcher.method = $0.isEmpty ? nil : $0 })) {
                    Text("Any").tag("")
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE"], id: \.self) { Text($0).tag($0) }
                }
                TextField("Status", value: $rule.status, format: .number.grouping(.never)).frame(width: 80)
            }
            TextField("URL pattern", text: $rule.matcher.urlPattern)
            Picker("Body", selection: $useFile) {
                Text("Inline").tag(false)
                Text("File").tag(true)
            }
            .pickerStyle(.segmented)
            if useFile {
                HStack {
                    TextField("Path", text: $rule.filePath.orEmpty)
                    Button("Choose…") { choose() }
                }
            } else {
                TextEditor(text: Binding(
                    get: { String(data: rule.body, encoding: .utf8) ?? "" },
                    set: { rule.body = Data($0.utf8) }
                ))
                .font(.body.monospaced()).frame(minHeight: 120).border(.separator)
            }
            Text("Headers (Name: value)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $headersText).font(.body.monospaced()).frame(height: 80).border(.separator)
        }
        .formStyle(.columns)
        .padding(12)
        .onAppear {
            useFile = rule.filePath != nil
            headersText = HeaderText.format(rule.headers)
        }
        .onChange(of: useFile) { _, file in
            if !file { rule.filePath = nil } else if rule.filePath == nil { rule.filePath = "" }
        }
        .onChange(of: headersText) { _, text in
            rule.headers = HeaderText.parse(text)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { rule.filePath = url.path }
    }
}
