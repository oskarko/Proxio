import Foundation
import ProxioCore
import ProxioProxy
import ProxioSystem

setlinebuf(stdout)

let usage = """
Usage:
  proxio-cli run [port] [--mitm] [--include PATTERN]... [--exclude PATTERN]... [--system-proxy] [--yes]
  proxio-cli ca path|status|install|migrate|uninstall [--yes]
  proxio-cli system-proxy status|on [port]|off [--yes]

Anything that changes your system (keychain, network settings) prints the exact
command and asks for confirmation first. --yes skips the question.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
let assumeYes = args.contains("--yes")
args.removeAll { $0 == "--yes" }

func confirmKeyMigration() -> Bool {
    print("Found a plaintext CA key (ca-key.pem). Move it into your login keychain and delete the file?")
    return confirm("Migrate?")
}

func confirm(_ question: String) -> Bool {
    if assumeYes { return true }
    print("\(question) [y/N] ", terminator: "")
    return (readLine() ?? "").lowercased().hasPrefix("y")
}

func values(of flag: String) -> [String] {
    var out: [String] = []
    var i = 0
    while i < args.count {
        if args[i] == flag, i + 1 < args.count { out.append(args[i + 1]); i += 1 }
        i += 1
    }
    return out
}

func patterns(_ flag: String) -> [HostPattern] {
    values(of: flag).map { text in
        guard let pattern = HostPattern(text) else { fail("Invalid pattern for \(flag): \(text)") }
        return pattern
    }
}

let caCertificate = CertificateAuthority.defaultDirectory.appendingPathComponent("ca.pem")
let snapshots = ProxySnapshotStore()

func enableSystemProxy(port: Int) throws {
    let proxy = SystemProxy()
    let service = try proxy.activeService()
    print("This will point the HTTP and HTTPS proxy of network service \"\(service)\" at 127.0.0.1:\(port)")
    print("(networksetup -setwebproxy / -setsecurewebproxy). Previous settings are saved and restored on 'off'.")
    guard confirm("Proceed?") else { fail("Cancelled.") }
    let previous = try proxy.enable(host: "127.0.0.1", port: port, service: service)
    if snapshots.load() == nil { try snapshots.save(previous) }   // never overwrite the original with our own settings
    print("System proxy enabled on \(service).")
}

func disableSystemProxy() throws {
    guard let snapshot = snapshots.load() else { print("Nothing to restore."); return }
    print("This will restore the previous proxy settings of \"\(snapshot.service)\".")
    guard confirm("Proceed?") else { fail("Cancelled.") }
    try SystemProxy().restore(snapshot)
    snapshots.clear()
    print("System proxy restored.")
}

guard let command = args.first else { fail(usage) }
let rest = Array(args.dropFirst())

switch command {
case "ca":
    switch rest.first {
    case "path":
        print(caCertificate.path)
    case "status":
        guard FileManager.default.fileExists(atPath: caCertificate.path) else { print("No CA yet. Run `proxio-cli run --mitm` once to create it."); break }
        print(try CATrust().isTrusted(certificate: caCertificate) ? "trusted" : "not trusted")
    case "install":
        _ = try CertificateAuthority.loadOrCreate(confirmMigration: confirmKeyMigration)
        let trust = CATrust()
        print("This adds the Proxio root CA as a trusted root in your login keychain by running:")
        print("  " + trust.installCommand(certificate: caCertificate).joined(separator: " "))
        print("While trusted, anyone who can read the CA private key can impersonate any site to this Mac.")
        print(CertificateAuthority.hasLegacyKey()
            ? "The key is still the plaintext file \(caCertificate.deletingLastPathComponent().path)/ca-key.pem (run `proxio-cli ca migrate` to move it into your Keychain)."
            : "The key is stored in your login keychain.")
        guard confirm("Proceed?") else { fail("Cancelled.") }
        try trust.install(certificate: caCertificate)
        print("Installed. macOS may have asked for your password.")
    case "migrate":
        guard CertificateAuthority.hasLegacyKey() else { print("Nothing to migrate: no ca-key.pem found."); break }
        _ = try CertificateAuthority.loadOrCreate(confirmMigration: confirmKeyMigration)
        print(CertificateAuthority.hasLegacyKey() ? "Not migrated." : "Key moved into your login keychain and ca-key.pem deleted.")
    case "uninstall":
        guard confirm("Remove the Proxio root CA from your login keychain?") else { fail("Cancelled.") }
        try CATrust().uninstall(certificate: caCertificate)
        print("Removed.")
    default: fail(usage)
    }

case "system-proxy":
    switch rest.first {
    case "status":
        let proxy = SystemProxy()
        let service = try proxy.activeService()
        let now = try proxy.snapshot(service: service)
        print("service: \(service)")
        print("http:  \(now.web)")
        print("https: \(now.secureWeb)")
        print(snapshots.load() == nil ? "proxio has not changed anything" : "proxio saved the previous settings; run `system-proxy off` to restore")
    case "on": try enableSystemProxy(port: rest.dropFirst().first.flatMap { Int($0) } ?? 9090)
    case "off": try disableSystemProxy()
    default: fail(usage)
    }

case "run":
    let port = rest.compactMap { Int($0) }.first ?? 9090
    let useMITM = rest.contains("--mitm")
    let ca = useMITM ? try CertificateAuthority.loadOrCreate(confirmMigration: confirmKeyMigration) : nil
    let rules = SSLProxyingRules(include: patterns("--include"), exclude: patterns("--exclude"), interceptByDefault: values(of: "--include").isEmpty)
    let store = FlowStore()
    let server = try ProxyServer(store: store, port: port, ca: ca, sslProxying: SSLProxyingPolicy(rules))
    let bound = try await server.start()
    print("Proxio listening on 127.0.0.1:\(bound)\(useMITM ? " (HTTPS interception on)" : "")")
    if useMITM, try !CATrust().isTrusted(certificate: caCertificate) {
        print("Note: the CA is not trusted by this Mac yet (`proxio-cli ca install`); browsers will warn.")
    }
    let systemProxy = rest.contains("--system-proxy")
    if systemProxy { try enableSystemProxy(port: bound) }

    nonisolated(unsafe) var stop = false
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { stop = true }
    sigint.resume()

    var printed = 0
    while !stop {
        try await Task.sleep(nanoseconds: 300_000_000)
        let flows = await store.all()
        for f in flows.dropFirst(printed) {
            print("\(f.request.method) \(f.request.url.absoluteString) -> \(f.response?.status ?? 0)")
        }
        printed = flows.count
    }
    if systemProxy, let snapshot = snapshots.load() {
        try? SystemProxy().restore(snapshot)
        snapshots.clear()
        print("System proxy restored.")
    }
    try await server.stop()

default:
    fail(usage)
}
