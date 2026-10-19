import SwiftUI
import ProxioCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSetup = false
    @State private var showBreakpoints = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.hostFilter) {
                Label("All (\(model.flows.count))", systemImage: "tray.full").tag(String?.none)
                Section("Domains") {
                    ForEach(model.hosts, id: \.host) { entry in
                        HStack { Text(entry.host).lineLimit(1); Spacer(); Text("\(entry.count)").foregroundStyle(.secondary) }
                            .tag(Optional(entry.host))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 220)
        } content: {
            Table(model.visibleFlows, selection: $model.selection) {
                TableColumn("#") { f in Text("\((model.flows.firstIndex { $0.id == f.id } ?? 0) + 1)").foregroundStyle(.secondary) }.width(40)
                TableColumn("Method") { Text($0.request.method).bold() }.width(60)
                TableColumn("URL") { f in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(f.request.url.path.isEmpty ? "/" : f.request.url.path).lineLimit(1)
                        Text(f.request.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Status") { f in
                    Text(f.response.map { String($0.status) } ?? "—").foregroundStyle(color(f.response?.status))
                }.width(55)
                TableColumn("Size") { Text($0.response.map { BodyFormatter.byteCount($0.body.count) } ?? "") }.width(70)
                TableColumn("Time") { Text($0.duration > 0 ? "\(Int($0.duration * 1000)) ms" : "") }.width(65)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let flow = model.flows.first(where: { $0.id == id }) {
                    Button("Copy as cURL") { model.copyCURL(flow) }
                    Button("Add Breakpoint for \(flow.request.url.host ?? "host")") { model.addBreakpoint(for: flow) }
                }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 560)
        } detail: {
            if let flow = model.selectedFlow {
                InspectorView(flow: flow).id(flow.id)
            } else {
                ContentUnavailableView("Select a request", systemImage: "arrow.left.arrow.right", description: Text(model.status))
            }
        }
        .searchable(text: $model.searchText, prompt: "Filter by URL, method, status or type")
        .toolbar {
            ToolbarItemGroup {
                Button { model.toggleProxy() } label: {
                    Label(model.isRunning ? "Stop" : "Start", systemImage: model.isRunning ? "stop.fill" : "play.fill")
                }
                .help(model.isRunning ? "Stop the proxy" : "Start the proxy")
                Button { model.clear() } label: { Label("Clear", systemImage: "trash") }
                Button { model.exportHAR() } label: { Label("Export HAR", systemImage: "square.and.arrow.up") }
                    .disabled(model.flows.isEmpty)
                Button { showBreakpoints = true } label: {
                    Label("Breakpoints", systemImage: model.paused.isEmpty ? "pause.circle" : "pause.circle.fill")
                }
                .badge(model.paused.count)
                Button { showSetup = true } label: { Label("Setup", systemImage: "gearshape") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle().fill(model.isRunning ? .green : .secondary).frame(width: 8, height: 8)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.visibleFlows.count) requests").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 4).background(.bar)
        }
        .sheet(isPresented: $showSetup) { SetupView(model: model) }
        .sheet(isPresented: $showBreakpoints) { BreakpointsView(model: model) }
        .sheet(item: Binding(get: { model.paused.first }, set: { _ in })) { PausedEditor(message: $0, model: model).id($0.id) }
    }

    private func color(_ status: Int?) -> Color {
        guard let status else { return .secondary }
        switch status {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }
}

struct SetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Proxy") {
                LabeledContent("Port") {
                    TextField("", value: $model.port, format: .number.grouping(.never)).frame(width: 80).disabled(model.isRunning)
                }
                Toggle("Intercept HTTPS (decrypt traffic)", isOn: $model.interceptHTTPS).disabled(model.isRunning)
            }
            Section("Certificate") {
                LabeledContent("Root certificate") {
                    Text(model.caTrusted ? "Trusted on this Mac" : "Not trusted").foregroundStyle(model.caTrusted ? .green : .orange)
                }
                HStack {
                    Button("Install and Trust…") { Task { await model.installCA() } }.disabled(model.caTrusted)
                    Button("Remove…") { Task { await model.uninstallCA() } }.disabled(!model.caTrusted)
                }
                Text("Nothing is installed until you confirm the exact command.").font(.caption).foregroundStyle(.secondary)
            }
            Section("System") {
                Toggle("Use as system proxy", isOn: Binding(
                    get: { model.systemProxyOn },
                    set: { on in Task { await model.setSystemProxy(on) } }
                )).disabled(!model.isRunning)
            }
            Section("SSL proxying") {
                Text("One pattern per line: host, *.host, or host:port. Exclusions win. With no inclusions every host is intercepted.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.includeText).font(.body.monospaced()).frame(height: 70)
                    .overlay(alignment: .topLeading) { if model.includeText.isEmpty { Text("Include…").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) } }
                TextEditor(text: $model.excludeText).font(.body.monospaced()).frame(height: 70)
                    .overlay(alignment: .topLeading) { if model.excludeText.isEmpty { Text("Exclude… e.g. *.apple.com").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .onChange(of: model.includeText) { model.applyRules() }
        .onChange(of: model.excludeText) { model.applyRules() }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await model.refreshSystemState() }
    }
}
