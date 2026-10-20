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
    var selection: Set<UUID> = []
    var searchText = ""
    var hostFilter: String?
    var quickFilter: QuickFilter = .all

    enum QuickFilter: String, CaseIterable, Identifiable {
        case all, https, webSocket, errors
        var id: String { rawValue }
    }

    // Sheets (also opened from the menu bar)
    var showSetup = false
    var showBreakpoints = false
    var showMapRules = false
    var showScripting = false
    var helperState: HelperState = HelperInstaller().state
    var showDiff = false
    var showMobile = false
    /// Listen on all interfaces so phones on the same network can use the proxy.
    var allowLAN = false
    /// Bumped when the imported schemas change so the inspector re-renders.
    var selectionRevision = 0

    // Proxy
    var port = 9090
    var interceptHTTPS = true
    var isRunning = false
    var status = String(localized: "Stopped")

    // System
    var caTrusted = false
    var systemProxyOn = false

    // Breakpoints
    var breakpoints: [Breakpoint] = [] { didSet { rules.breakpoints = breakpoints; scheduleSave() } }
    var paused: [PausedMessage] = []

    // Compose / Repeat: non-nil while the composer is open
    var composeDraft: HTTPRequestRecord?

    // Rewrite rules
    var mapLocalRules: [MapLocalRule] = [] { didSet { rules.mapLocalRules = mapLocalRules; scheduleSave() } }
    var mapRemoteRules: [MapRemoteRule] = [] { didSet { rules.mapRemoteRules = mapRemoteRules; scheduleSave() } }
    var scripts: [ProxioScript] = [] { didSet { rules.scripts = scripts; scheduleSave() } }
    /// Recent `console.log` output from scripts, newest last.
    var scriptLog: [String] = []

    // SSL proxying (one pattern per line)
    var includeText = ""
    var excludeText = ""

    let store = FlowStore()
    private let policy = SSLProxyingPolicy()
    private let rules = TrafficRules()
    private let bridge = BreakpointBridge()
    private let rulesStore = RulesStore()
    private var saveTask: Task<Void, Never>?
    private var server: ProxyServer?
    private var observer: Task<Void, Never>?
    private let snapshots = ProxySnapshotStore()
    private var ca: CertificateAuthority?

    init() {
        observer = Task { [store] in
            for await snapshot in store.changes() { self.flows = snapshot }
        }
        bridge.model = self
        let saved = rulesStore.load()
        breakpoints = saved.breakpoints
        mapLocalRules = saved.mapLocal
        mapRemoteRules = saved.mapRemote
        scripts = saved.scripts
        // didSet observers do not run inside init, so hand the loaded rules to the proxy explicitly.
        rules.breakpoints = saved.breakpoints
        rules.mapLocalRules = saved.mapLocal
        rules.mapRemoteRules = saved.mapRemote
        rules.scripts = saved.scripts
        rules.scriptEngine.onLog = { [weak self] name, text in
            Task { @MainActor in
                guard let self else { return }
                self.scriptLog.append("[\(name)] \(text)")
                if self.scriptLog.count > 500 { self.scriptLog.removeFirst(self.scriptLog.count - 500) }
            }
        }
        rules.breakpointHandler = bridge
        applyRules()
        Task { await refreshSystemState() }
    }

    /// Writes the rules shortly after the last edit, so typing in a field does not hit the disk per keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try rulesStore.save(RulesDocument(breakpoints: breakpoints, mapLocal: mapLocalRules, mapRemote: mapRemoteRules, scripts: scripts))
            } catch { status = String(localized: "Could not save rules: \(error.localizedDescription)") }
        }
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
                && passes(quickFilter, f)
                && (searchText.isEmpty || matches(f, searchText))
        }
    }

    /// The flow shown in the inspector: only when exactly one is selected.
    var selectedFlow: Flow? { selection.count == 1 ? flows.first { $0.id == selection.first } : nil }

    /// Two selected flows, in capture order, ready to compare.
    var selectedPair: (Flow, Flow)? {
        guard selection.count == 2 else { return nil }
        let pair = flows.filter { selection.contains($0.id) }
        return pair.count == 2 ? (pair[0], pair[1]) : nil
    }

    private func passes(_ filter: QuickFilter, _ f: Flow) -> Bool {
        switch filter {
        case .all: true
        case .https: f.request.url.scheme == "https"
        case .webSocket: f.isWebSocket
        case .errors: (f.response?.status ?? 0) >= 400
        }
    }

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
            ca = interceptHTTPS ? try CertificateAuthority.loadOrCreate(confirmMigration: confirmKeyMigration) : nil
            applyRules()
            let host = allowLAN ? "0.0.0.0" : "127.0.0.1"
            let server = try ProxyServer(store: store, host: host, port: port, ca: ca, sslProxying: policy, rules: rules)
            port = try await server.start()
            self.server = server
            isRunning = true
            status = String(localized: "Listening on \(host):\(port)") + (interceptHTTPS ? " · " + String(localized: "HTTPS interception on") : "")
            await refreshSystemState()
        } catch {
            status = String(localized: "Could not start: \(error.localizedDescription)")
        }
    }

    func stop() async {
        if systemProxyOn { await setSystemProxy(false) }
        for message in paused { release(message, with: nil) }
        try? await server?.stop()
        server = nil
        isRunning = false
        status = String(localized: "Stopped")
    }

    func clear() {
        selection = []
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
        catch { status = String(localized: "Export failed: \(error.localizedDescription)") }
    }

    /// `simctl keychain booted add-root-cert`: the simulators' trust store, not the Mac's.
    func installCAInSimulators() async {
        let pem = caURL.path
        guard FileManager.default.fileExists(atPath: pem) else {
            status = String(localized: "Start the proxy with HTTPS interception first")
            return
        }
        let result: (Int32, String) = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["simctl", "keychain", "booted", "add-root-cert", pem]
            let pipe = Pipe()
            p.standardError = pipe; p.standardOutput = pipe
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }.value
        status = result.0 == 0
            ? String(localized: "Certificate installed in booted simulators")
            : String(localized: "Could not install in simulators: \(result.1.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    func importProtos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "proto") ?? .data]
        guard panel.runModal() == .OK else { return }
        let bad = ProtoRegistry.shared.importFiles(panel.urls)
        status = bad.isEmpty ? String(localized: "Imported .proto files") : String(localized: "Could not parse: \(bad.joined(separator: ", "))")
        selectionRevision += 1
    }

    func clearProtos() {
        ProtoRegistry.shared.clear()
        selectionRevision += 1
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

    private func confirmKeyMigration() -> Bool {
        confirm(
            title: String(localized: "Move the CA key into your Keychain?"),
            message: String(localized: "Proxio found its CA private key as a plaintext file (ca-key.pem). It can be stored in your login keychain instead; the file is then overwritten and deleted."),
            action: String(localized: "Move to Keychain")
        )
    }

    func installCA() async {
        do {
            _ = try CertificateAuthority.loadOrCreate(confirmMigration: confirmKeyMigration)
            let trust = CATrust()
            let url = caURL
            let command = trust.installCommand(certificate: url).joined(separator: " ")
            guard confirm(
                title: String(localized: "Trust the Proxio root certificate?"),
                message: String(localized: "Proxio will run:\n\n\(command)\n\nWhile it is trusted, anyone who can read the CA private key can impersonate any website to this Mac. macOS will ask for your password."),
                action: String(localized: "Install and Trust")
            ) else { return }
            try await Task.detached { try trust.install(certificate: url) }.value
            await refreshSystemState()
        } catch { status = String(localized: "CA install failed: \(error.localizedDescription)") }
    }

    func uninstallCA() async {
        guard confirm(title: String(localized: "Remove the Proxio root certificate?"), message: String(localized: "It will no longer be trusted and will be deleted from your login keychain."), action: String(localized: "Remove")) else { return }
        let url = caURL
        do {
            try await Task.detached { try CATrust().uninstall(certificate: url) }.value
            await refreshSystemState()
        } catch { status = String(localized: "CA removal failed: \(error.localizedDescription)") }
    }

    func installHelper() {
        do { try HelperInstaller().register() } catch { status = String(localized: "Helper change failed: \(error.localizedDescription)") }
        helperState = HelperInstaller().state
        if helperState == .requiresApproval { HelperInstaller().openLoginItemsSettings() }
    }

    func removeHelper() {
        do { try HelperInstaller().unregister() } catch { status = String(localized: "Helper change failed: \(error.localizedDescription)") }
        helperState = HelperInstaller().state
    }

    func revealCertificate() {
        NSWorkspace.shared.activateFileViewerSelecting([caURL])
    }

    func setSystemProxy(_ on: Bool) async {
        let port = self.port
        let snapshots = self.snapshots
        do {
            if on {
                let service = try await Task.detached { try SystemProxy().activeService() }.value
                guard confirm(
                    title: String(localized: "Route \(service) traffic through Proxio?"),
                    message: String(localized: "The HTTP and HTTPS proxy of \"\(service)\" will be set to 127.0.0.1:\(port). Your current settings are saved and restored when you turn this off or stop the proxy."),
                    action: String(localized: "Enable")
                ) else { return }
                let previous: ProxySnapshot
                if helperState == .enabled, let viaHelper = try? await HelperClient().enableProxy(port: port, service: service) {
                    previous = viaHelper
                } else {
                    previous = try await Task.detached { try SystemProxy().enable(host: "127.0.0.1", port: port, service: service) }.value
                }
                if snapshots.load() == nil { try snapshots.save(previous) }
            } else if let snapshot = snapshots.load() {
                if helperState == .enabled, (try? await HelperClient().restoreProxy(snapshot)) != nil {
                    // restored without a password prompt
                } else {
                    try await Task.detached { try SystemProxy().restore(snapshot) }.value
                }
                snapshots.clear()
            }
            systemProxyOn = snapshots.load() != nil
        } catch { status = String(localized: "System proxy change failed: \(error.localizedDescription)") }
    }

    private func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
