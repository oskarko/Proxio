import SwiftUI
import ProxioCore
import ProxioSystem

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230)
        } detail: {
            VSplitView {
                VStack(spacing: 0) {
                    QuickFilterBar(model: model)
                    Divider()
                    FlowTable(model: model)
                }
                .frame(minHeight: 160, idealHeight: 280)
                Detail(model: model)
                    .frame(minHeight: 200, idealHeight: 340)
            }
        }
        .searchable(text: $model.searchText, prompt: "Filter by URL, method, status or type")
        .toolbar { MainToolbar(model: model) }
        .safeAreaInset(edge: .bottom) { StatusBar(model: model) }
        .sheet(isPresented: $model.showSetup) { SetupView(model: model) }
        .sheet(isPresented: $model.showNetwork) { NetworkConditionsView(model: model) }
        .sheet(isPresented: $model.showMobile) { MobileSetupView(model: model) }
        .sheet(isPresented: Binding(get: { model.composeDraft != nil }, set: { if !$0 { model.composeDraft = nil } })) {
            ComposeView(model: model)
        }
        .sheet(isPresented: $model.showDiff) {
            if let (a, b) = model.selectedPair { DiffView(a: a, b: b) }
        }
        .sheet(isPresented: $model.showMapRules) { MapRulesView(model: model) }
        .sheet(isPresented: $model.showBreakpoints) { BreakpointsView(model: model) }
        .sheet(isPresented: $model.showScripting) { ScriptingView(model: model) }
        .sheet(item: Binding(get: { model.paused.first }, set: { _ in })) { PausedEditor(message: $0, model: model).id($0.id) }
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.hostFilter) {
            Label("All Traffic", systemImage: "tray.full")
                .badge(model.flows.count)
                .tag(String?.none)
            Section("Domains") {
                ForEach(model.hosts, id: \.host) { entry in
                    Label(entry.host, systemImage: "globe")
                        .lineLimit(1)
                        .badge(entry.count)
                        .tag(Optional(entry.host))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                AnchorMark(lineWidthRatio: 0.07).frame(width: 18, height: 18).foregroundStyle(Color.proxioAccent)
                Text("Proxio").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

// MARK: Request list

private struct QuickFilterBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack {
            Picker("", selection: $model.quickFilter) {
                ForEach(AppModel.QuickFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 330)
            Spacer()
            Text("\(model.visibleFlows.count) requests").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

extension AppModel.QuickFilter {
    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .https: "HTTPS"
        case .webSocket: "WebSocket"
        case .errors: "Errors"
        }
    }
}

private struct FlowTable: View {
    @Bindable var model: AppModel

    var body: some View {
        Table(model.visibleFlows, selection: $model.selection) {
            TableColumn("#") { f in Text("\((model.flows.firstIndex { $0.id == f.id } ?? 0) + 1)").foregroundStyle(.secondary) }.width(40)
            TableColumn("URL") { f in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: f)).foregroundStyle(f.isWebSocket ? Color.proxioAccent : .secondary).frame(width: 14)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(f.request.url.path.isEmpty ? "/" : f.request.url.path).lineLimit(1)
                        Text(f.request.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("Method") { Text($0.request.method).bold() }.width(70)
            TableColumn("Code") { f in
                Text(f.response.map { String($0.status) } ?? "—").foregroundStyle(color(f.response?.status))
            }.width(55)
            TableColumn("Size") { Text($0.response.map { BodyFormatter.byteCount($0.body.count) } ?? "") }.width(70)
            TableColumn("Time") { Text($0.duration > 0 ? "\(Int($0.duration * 1000)) ms" : "") }.width(70)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 2 {
                Button("Compare") { model.selection = ids; model.showDiff = true }
            } else if ids.count == 1, let id = ids.first, let flow = model.flows.first(where: { $0.id == id }) {
                Button("Copy as cURL") { model.copyCURL(flow) }
                if flow.request.method != "CONNECT" {
                    Button("Repeat") { model.repeatRequest(flow) }
                    Button("Edit and Repeat…") { model.compose(from: flow) }
                }
                if flow.response != nil, flow.request.method != "CONNECT" {
                    Button("Map Local with This Response") { model.mapLocal(from: flow); model.showMapRules = true }
                }
                Button("Add Breakpoint for \(flow.request.url.host ?? "host")") { model.addBreakpoint(for: flow) }
            }
        }
    }

    private func icon(for flow: Flow) -> String {
        if flow.isWebSocket { return "bolt.horizontal.fill" }
        if flow.request.method == "CONNECT" { return "lock.shield" }
        return flow.request.url.scheme == "https" ? "lock.fill" : "globe"
    }

    private func color(_ status: Int?) -> Color {
        guard let status else { return .secondary }
        switch status {
        case 200..<300: return .green
        case 300..<400: return .proxioAccent
        case 400..<500: return .orange
        default: return .red
        }
    }
}

// MARK: Detail

private struct Detail: View {
    @Bindable var model: AppModel

    var body: some View {
        if let flow = model.selectedFlow {
            InspectorView(flow: flow).id("\(flow.id)-\(model.selectionRevision)")
        } else if model.selectedPair != nil {
            ContentUnavailableView {
                Label("2 requests selected", systemImage: "arrow.left.arrow.right.square")
            } actions: {
                Button("Compare") { model.showDiff = true }.buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label { Text("Select a request") } icon: {
                    AnchorMark(lineWidthRatio: 0.05).frame(width: 56, height: 56).foregroundStyle(Color.proxioAccent.opacity(0.7))
                }
            } description: {
                Text(model.status)
            }
        }
    }
}

// MARK: Toolbar and status bar

private struct MainToolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.toggleProxy() } label: {
                Label(model.isRunning ? "Stop" : "Start", systemImage: model.isRunning ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(model.isRunning ? Color.red : Color.proxioAccent)
            }
            .help(model.isRunning ? "Stop the proxy" : "Start the proxy")
            Button { model.clear() } label: { Label("Clear", systemImage: "trash") }
                .help("Clear session")
        }
        ToolbarItem(placement: .principal) {
            Button { model.showSetup = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(model.isRunning ? Color.proxioAccent : Color.secondary).frame(width: 8, height: 8)
                    Text(model.isRunning ? "127.0.0.1:\(model.port)" : "Not recording").font(.callout)
                    if model.isRunning && model.interceptHTTPS { Image(systemName: "lock.open.fill").font(.caption).foregroundStyle(Color.proxioAccent) }
                }
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Proxy settings")
        }
        ToolbarItemGroup {
            Button { model.showBreakpoints = true } label: {
                Label("Breakpoints", systemImage: model.paused.isEmpty ? "pause.circle" : "pause.circle.fill")
            }
            .badge(model.paused.count)
            Button { model.showMapRules = true } label: { Label("Map Local / Remote", systemImage: "arrow.triangle.swap") }
            Button { model.compose(from: model.selectedFlow.flatMap { $0.request.method == "CONNECT" ? nil : $0 }) } label: {
                Label("Compose", systemImage: "square.and.pencil")
            }
            Button { model.showDiff = true } label: { Label("Compare", systemImage: "arrow.left.arrow.right.square") }
                .disabled(model.selectedPair == nil)
                .help("Select two requests to compare them")
            Button { model.showSetup = true } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}

private struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack {
            Circle().fill(model.isRunning ? Color.proxioAccent : .secondary).frame(width: 8, height: 8)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !model.networkProfile.isTransparent {
                Label(LocalizedStringKey(model.networkProfile.name), systemImage: "gauge.with.dots.needle.33percent").font(.caption).foregroundStyle(.orange)
            }
            if model.systemProxyOn { Label("System proxy on", systemImage: "network").font(.caption).foregroundStyle(.secondary) }
            if model.caTrusted { Label("Certificate trusted", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 4).background(.bar)
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
                HelperRow(model: model)
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

private struct HelperRow: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.helperState {
        case .unavailable:
            Text("The privileged helper is not part of this build, so macOS may ask for your password when the system proxy changes.")
                .font(.caption).foregroundStyle(.secondary)
        case .notRegistered:
            HStack {
                Text("Privileged helper: not installed").foregroundStyle(.secondary)
                Spacer()
                Button("Install…") { model.installHelper() }
            }
            Text("Lets Proxio change the system proxy without asking for your password each time. It can only set 127.0.0.1 and restore the previous setting.")
                .font(.caption).foregroundStyle(.secondary)
        case .requiresApproval:
            HStack {
                Text("Privileged helper: waiting for approval").foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items…") { HelperInstaller().openLoginItemsSettings() }
                Button("Remove") { model.removeHelper() }
            }
        case .enabled:
            HStack {
                Label("Privileged helper active", systemImage: "checkmark.shield")
                Spacer()
                Button("Remove") { model.removeHelper() }
            }
        }
    }
}
