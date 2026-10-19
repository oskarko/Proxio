import SwiftUI
import ProxioCore

struct ScriptingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Scripts can change matching requests and responses with JavaScript. Define onRequest(request) and/or onResponse(request, response) and return the object. Keep scripts short: a script that never returns blocks its request.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Divider()
            HSplitView {
                List(selection: $selected) {
                    ForEach($model.scripts) { $script in
                        HStack {
                            Toggle("", isOn: $script.isEnabled).labelsHidden()
                            VStack(alignment: .leading) {
                                Text(script.name).lineLimit(1)
                                Text(script.matcher.urlPattern.isEmpty ? String(localized: "(any)") : script.matcher.urlPattern)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.tag(script.id)
                    }
                    .onDelete { model.scripts.remove(atOffsets: $0) }
                }
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
                .overlay { if model.scripts.isEmpty { ContentUnavailableView("No scripts", systemImage: "curlybraces") } }

                if let index = model.scripts.firstIndex(where: { $0.id == selected }) {
                    ScriptEditor(script: $model.scripts[index]).id(model.scripts[index].id)
                } else {
                    ContentUnavailableView("Select a script", systemImage: "sidebar.left").frame(maxWidth: .infinity)
                }
            }
            if showLog {
                Divider()
                ScrollView {
                    Text(model.scriptLog.isEmpty ? String(localized: "No console output yet") : model.scriptLog.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 110)
            }
            Divider()
            HStack {
                Button("Add") {
                    let script = ProxioScript(name: String(localized: "New script"))
                    model.scripts.append(script)
                    selected = script.id
                }
                Toggle("Console", isOn: $showLog).toggleStyle(.button)
                if showLog { Button("Clear") { model.scriptLog.removeAll() } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 860, height: 600)
    }
}

private struct ScriptEditor: View {
    @Binding var script: ProxioScript

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $script.name)
                Picker("Method", selection: Binding(get: { script.matcher.method ?? "" }, set: { script.matcher.method = $0.isEmpty ? nil : $0 })) {
                    Text("Any").tag("")
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 160)
            }
            TextField("URL pattern", text: $script.matcher.urlPattern)
            TextEditor(text: $script.source)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
    }
}
