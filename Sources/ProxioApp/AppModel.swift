import SwiftUI
import AppKit
import ProxioCore
import ProxioProxy
import ProxioSystem

@MainActor
@Observable
final class AppModel {
    // Capture
    var flows: [Flow] = []
    var selection: UUID?
    var searchText = ""
    var hostFilter: String?

    // Proxy
    var port = 9090
    var interceptHTTPS = true
    var isRunning = false
    var status = "Stopped"

    // System
    var caTrusted = false
    var systemProxyOn = false

    // SSL proxying (one pattern per line)
    var includeText = ""
    var excludeText = ""

    private let store = FlowStore()
    private let policy = SSLProxyingPolicy()
    private var server: ProxyServer?
    private var observer: Task<Void, Never>?
    private let snapshots = ProxySnapshotStore()
    private var ca: CertificateAuthority?

    init() {
        observer = Task { [store] in
            for await snapshot in store.changes() { self.flows = snapshot }
        }
        applyRules()
        Task { await refreshSystemState() }
    }

    // MARK: Derived

    var hosts: [(host: String, count: Int)] {
        Dictionary(grouping: flows, by: { $0.request.url.host ?? "?" })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.host < $1.host }
    }

    var visibleFlows: [Flow] {
        flows.filter { f in
            (hostFilter == nil || f.request.url.host == hostFilter)
                && (searchText.isEmpty || matches(f, searchText))
        }
    }

    var selectedFlow: Flow? { flows.first { $0.id == selection } }

    private func matches(_ f: Flow, _ text: String) -> Bool {
        f.request.url.absoluteString.localizedCaseInsensitiveContains(text)
            || f.request.method.localizedCaseInsensitiveContains(text)
            || (f.response.map { String($0.status) }?.contains(text) ?? false)
            || (f.response?.mimeType.localizedCaseInsensitiveContains(text) ?? false)
    }

    // MARK: Proxy

    func toggleProxy() {
        Task { isRunning ? await stop() : await start() }
    }

    func start() async {
        do {
            ca = interceptHTTPS ? try CertificateAuthority.loadOrCreate() : nil
            applyRules()
            let server = try ProxyServer(store: store, port: port, ca: ca, sslProxying: policy)
            port = try await server.start()
            self.server = server
            isRunning = true
            status = "Listening on 127.0.0.1:\(port)" + (interceptHTTPS ? " · HTTPS interception on" : "")
            await refreshSystemState()
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    func stop() async {
        if systemProxyOn { await setSystemProxy(false) }
        try? await server?.stop()
        server = nil
        isRunning = false
        status = "Stopped"
    }

    func clear() {
        selection = nil
        Task { await store.clear() }
    }

    func applyRules() {
        func parse(_ text: String) -> [HostPattern] {
            text.split(whereSeparator: \.isNewline).compactMap { HostPattern(String($0)) }
        }
        let include = parse(includeText)
        policy.rules = SSLProxyingRules(include: include, exclude: parse(excludeText), interceptByDefault: include.isEmpty)
    }

    // MARK: Export / copy

    func copyCURL(_ flow: Flow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CURLExporter.command(for: flow.request), forType: .string)
    }

    func exportHAR() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxio.har"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = flows
        do { try HARExporter.export(snapshot).write(to: url) }
        catch { status = "Export failed: \(error.localizedDescription)" }
    }

    // MARK: System changes (always confirmed with the exact action)

    private var caURL: URL { CertificateAuthority.defaultDirectory.appendingPathComponent("ca.pem") }

    func refreshSystemState() async {
        let url = caURL
        let trusted = await Task.detached {
            FileManager.default.fileExists(atPath: url.path) && ((try? CATrust().isTrusted(certificate: url)) ?? false)
        }.value
        caTrusted = trusted
        systemProxyOn = snapshots.load() != nil
    }

    func installCA() async {
        do {
            _ = try CertificateAuthority.loadOrCreate()
            let trust = CATrust()
            let url = caURL
            let command = trust.installCommand(certificate: url).joined(separator: " ")
            guard confirm(
                title: "Trust the Proxio root certificate?",
                message: "Proxio will run:\n\n\(command)\n\nWhile it is trusted, anyone who obtains \(url.deletingLastPathComponent().path)/ca-key.pem can impersonate any website to this Mac. macOS will ask for your password.",
                action: "Install and Trust"
            ) else { return }
            try await Task.detached { try trust.install(certificate: url) }.value
            await refreshSystemState()
        } catch { status = "CA install failed: \(error)" }
    }

    func uninstallCA() async {
        guard confirm(title: "Remove the Proxio root certificate?", message: "It will no longer be trusted and will be deleted from your login keychain.", action: "Remove") else { return }
        let url = caURL
        do {
            try await Task.detached { try CATrust().uninstall(certificate: url) }.value
            await refreshSystemState()
        } catch { status = "CA removal failed: \(error)" }
    }

    func setSystemProxy(_ on: Bool) async {
        let port = self.port
        let snapshots = self.snapshots
        do {
            if on {
                let service = try await Task.detached { try SystemProxy().activeService() }.value
                guard confirm(
                    title: "Route \(service) traffic through Proxio?",
                    message: "The HTTP and HTTPS proxy of \"\(service)\" will be set to 127.0.0.1:\(port). Your current settings are saved and restored when you turn this off or stop the proxy.",
                    action: "Enable"
                ) else { return }
                let previous = try await Task.detached { try SystemProxy().enable(host: "127.0.0.1", port: port, service: service) }.value
                if snapshots.load() == nil { try snapshots.save(previous) }
            } else if let snapshot = snapshots.load() {
                try await Task.detached { try SystemProxy().restore(snapshot) }.value
                snapshots.clear()
            }
            systemProxyOn = snapshots.load() != nil
        } catch { status = "System proxy change failed: \(error)" }
    }

    private func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
