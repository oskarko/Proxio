import SwiftUI
import AppKit

@main
struct ProxioApp: App {
    @State private var model = AppModel()

    init() {
        IconRenderer.renderIfRequested()
        // Running from `swift run` (no bundle) still needs a regular, activatable app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Proxio") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 560)
                .tint(.proxioAccent)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSetup = true }.keyboardShortcut(",")
            }
            CommandGroup(after: .importExport) {
                Button("Save Session…") { model.saveSession() }
                    .keyboardShortcut("s")
                    .disabled(model.flows.isEmpty)
                Button("Open Session…") { model.openSession() }.keyboardShortcut("o")
                Button("Import HAR…") { model.importHAR() }
                Divider()
                Button("Export as HAR…") { model.exportHAR() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.flows.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Clear Session") { model.clear() }.keyboardShortcut("k")
            }
            CommandMenu("Tools") {
                Button("Breakpoints…") { model.showBreakpoints = true }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Map Local / Remote…") { model.showMapRules = true }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Scripting…") { model.showScripting = true }.keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Block, Allow, DNS & Bypass…") { model.showAccess = true }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Network Conditions…") { model.showNetwork = true }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Set Up Device…") { model.showMobile = true }.keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Import .proto Files…") { model.importProtos() }
                Button("Remove Imported .proto Files") { model.clearProtos() }
                Divider()
                Button("Compose…") { model.compose(from: model.selectedFlow.flatMap { $0.request.method == "CONNECT" ? nil : $0 }) }
                    .keyboardShortcut("n")
                Button("Repeat Selected") { if let f = model.selectedFlow, f.request.method != "CONNECT" { model.repeatRequest(f) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Compare Selected") { model.showDiff = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.selectedPair == nil)
            }
            CommandMenu("Certificate") {
                Button("Install and Trust…") { Task { await model.installCA() } }.disabled(model.caTrusted)
                Button("Remove…") { Task { await model.uninstallCA() } }.disabled(!model.caTrusted)
                Divider()
                Button("Show Certificate in Finder") { model.revealCertificate() }
            }
            CommandMenu("Proxy") {
                Button(model.isRunning ? "Stop Recording" : "Start Recording") { model.toggleProxy() }.keyboardShortcut("r")
                Toggle("Use as System Proxy", isOn: Binding(
                    get: { model.systemProxyOn },
                    set: { on in Task { await model.setSystemProxy(on) } }
                )).disabled(!model.isRunning)
                Toggle("Intercept HTTPS", isOn: $model.interceptHTTPS).disabled(model.isRunning)
                Divider()
                Button("Proxy Settings…") { model.showSetup = true }
            }
            CommandGroup(replacing: .help) {
                Link("Proxio on GitHub", destination: URL(string: "https://github.com/oskarko/Proxio")!)
            }
        }
    }
}
