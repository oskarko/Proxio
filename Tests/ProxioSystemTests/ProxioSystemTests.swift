import Testing
import Foundation
@testable import ProxioSystem

/// Records every command and answers from a script; never touches the machine.
private final class FakeRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var responses: [String: CommandResult] = [:]   // key: space-joined args

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        calls.append([executable] + arguments)
        return responses[arguments.joined(separator: " ")] ?? CommandResult()
    }
}

private let serviceOrder = """
An asterisk (*) denotes that a network service is disabled.
(1) Ethernet
(Hardware Port: Ethernet, Device: en5)

(2) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)
"""

private func enabledProxy(_ host: String, _ port: Int) -> CommandResult {
    CommandResult(stdout: "Enabled: Yes\nServer: \(host)\nPort: \(port)\nAuthenticated Proxy Enabled: 0\n")
}
private let disabledProxy = CommandResult(stdout: "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n")

// MARK: CATrust

@Test func installCommandIsExplicitAndUserScoped() {
    let trust = CATrust(runner: FakeRunner(), keychain: "/k/login.keychain-db")
    let cmd = trust.installCommand(certificate: URL(fileURLWithPath: "/tmp/ca.pem"))
    #expect(cmd == ["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-k", "/k/login.keychain-db", "/tmp/ca.pem"])
    #expect(!cmd.contains("-d"))   // never the admin domain
}

@Test func installRunsOnlyTheShownCommand() throws {
    let runner = FakeRunner()
    try CATrust(runner: runner, keychain: "/k").install(certificate: URL(fileURLWithPath: "/tmp/ca.pem"))
    #expect(runner.calls == [["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-k", "/k", "/tmp/ca.pem"]])
}

@Test func installFailureSurfacesTheError() {
    let runner = FakeRunner()
    runner.responses["add-trusted-cert -r trustRoot -k /k /tmp/ca.pem"] = CommandResult(status: 1, stderr: "denied")
    #expect(throws: SystemCommandError.self) {
        try CATrust(runner: runner, keychain: "/k").install(certificate: URL(fileURLWithPath: "/tmp/ca.pem"))
    }
}

@Test func isTrustedReflectsExitStatus() throws {
    let runner = FakeRunner()
    let trust = CATrust(runner: runner, keychain: "/k")
    let ca = URL(fileURLWithPath: "/tmp/ca.pem")
    #expect(try trust.isTrusted(certificate: ca))
    runner.responses["verify-cert -c /tmp/ca.pem -p basic"] = CommandResult(status: 3)
    #expect(try !trust.isTrusted(certificate: ca))
}

@Test func uninstallRemovesTrustThenCertificate() throws {
    let runner = FakeRunner()
    try CATrust(runner: runner, keychain: "/k").uninstall(certificate: URL(fileURLWithPath: "/tmp/ca.pem"))
    #expect(runner.calls.map { $0[1] } == ["remove-trusted-cert", "delete-certificate"])
}

// MARK: SystemProxy

@Test func findsServiceOfTheDefaultRouteDevice() throws {
    let runner = FakeRunner()
    runner.responses["-n get default"] = CommandResult(stdout: "   route to: default\n  interface: en0\n")
    runner.responses["-listnetworkserviceorder"] = CommandResult(stdout: serviceOrder)
    #expect(try SystemProxy(runner: runner).activeService() == "Wi-Fi")
}

@Test func enableReturnsPreviousStateAndSetsBothProxies() throws {
    let runner = FakeRunner()
    runner.responses["-getwebproxy Wi-Fi"] = enabledProxy("corp.example", 3128)
    runner.responses["-getsecurewebproxy Wi-Fi"] = disabledProxy
    let previous = try SystemProxy(runner: runner).enable(host: "127.0.0.1", port: 9090, service: "Wi-Fi")

    #expect(previous.web == ProxyEndpoint(enabled: true, host: "corp.example", port: 3128))
    #expect(previous.secureWeb.enabled == false)
    let sets = runner.calls.filter { $0[1].hasPrefix("-set") }
    #expect(sets == [
        ["/usr/sbin/networksetup", "-setwebproxy", "Wi-Fi", "127.0.0.1", "9090"],
        ["/usr/sbin/networksetup", "-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "9090"],
    ])
}

@Test func restoreReappliesOrDisables() throws {
    let runner = FakeRunner()
    let snap = ProxySnapshot(
        service: "Wi-Fi",
        web: ProxyEndpoint(enabled: true, host: "corp.example", port: 3128),
        secureWeb: ProxyEndpoint(enabled: false)
    )
    try SystemProxy(runner: runner).restore(snap)
    #expect(runner.calls == [
        ["/usr/sbin/networksetup", "-setwebproxy", "Wi-Fi", "corp.example", "3128"],
        ["/usr/sbin/networksetup", "-setsecurewebproxystate", "Wi-Fi", "off"],
    ])
}

@Test func snapshotStoreRoundTrips() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("proxio-\(UUID().uuidString)/snap.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = ProxySnapshotStore(url: url)
    #expect(store.load() == nil)
    let snap = ProxySnapshot(service: "Wi-Fi", web: ProxyEndpoint(enabled: false), secureWeb: ProxyEndpoint(enabled: true, host: "h", port: 1))
    try store.save(snap)
    #expect(store.load() == snap)
    store.clear()
    #expect(store.load() == nil)
}

// MARK: - Privileged helper validation

@Suite struct HelperValidatorTests {
    let services = HelperValidator.services(fromListing: "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Thunderbolt Bridge\nUSB 10/100/1000 LAN\n")

    @Test func parsesEnabledServicesOnly() {
        #expect(services == ["Wi-Fi", "USB 10/100/1000 LAN"])
    }

    @Test func acceptsOnlyUsablePortsAndKnownServices() {
        #expect(HelperValidator.isValid(port: 8888))
        #expect(!HelperValidator.isValid(port: 0))
        #expect(!HelperValidator.isValid(port: 70000))
        #expect(HelperValidator.isKnown(service: "Wi-Fi", in: services))
        #expect(!HelperValidator.isKnown(service: "Wi-Fi; rm -rf /", in: services))
    }

    @Test func snapshotsMustNameAKnownServiceAndPlainHosts() {
        let good = ProxySnapshot(service: "Wi-Fi", web: ProxyEndpoint(enabled: true, host: "proxy.corp.example", port: 3128), secureWeb: ProxyEndpoint(enabled: false))
        #expect(HelperValidator.isValid(good, services: services))
        var badService = good; badService.service = "Other"
        #expect(!HelperValidator.isValid(badService, services: services))
        var badHost = good; badHost.web.host = "evil host;$(x)"
        #expect(!HelperValidator.isValid(badHost, services: services))
        var badPort = good; badPort.secureWeb.port = 99999
        #expect(!HelperValidator.isValid(badPort, services: services))
    }

    @Test func clientRequirementNeedsATeam() {
        #expect(HelperValidator.clientRequirement(teamIdentifier: "") == nil)
        #expect(HelperValidator.clientRequirement(teamIdentifier: "AB\"; or true") == nil)
        let r = HelperValidator.clientRequirement(teamIdentifier: "934NVR3K3Z")
        #expect(r?.contains("identifier \"dev.proxio.app\"") == true)
        #expect(r?.contains("leaf[subject.OU] = \"934NVR3K3Z\"") == true)
    }
}
