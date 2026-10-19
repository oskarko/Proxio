import Foundation

public struct ProxyEndpoint: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public init(enabled: Bool, host: String = "", port: Int = 0) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }
}

/// The HTTP and HTTPS proxy settings of one network service, as they were before Proxio changed them.
public struct ProxySnapshot: Codable, Sendable, Equatable {
    public var service: String
    public var web: ProxyEndpoint
    public var secureWeb: ProxyEndpoint
}

/// Points the macOS HTTP/HTTPS proxy of a network service at Proxio, and restores it afterwards.
public struct SystemProxy: Sendable {
    static let networksetup = "/usr/sbin/networksetup"
    static let route = "/sbin/route"

    private let runner: CommandRunner

    public init(runner: CommandRunner = ProcessRunner()) { self.runner = runner }

    /// Network service that carries the default route, e.g. "Wi-Fi".
    public func activeService() throws -> String {
        let routeOut = try runner.check(Self.route, ["-n", "get", "default"]).stdout
        guard let device = Self.value(of: "interface", in: routeOut) else {
            throw SystemCommandError(command: "route -n get default", result: CommandResult(status: 1, stderr: "no default route"))
        }
        let order = try runner.check(Self.networksetup, ["-listnetworkserviceorder"]).stdout
        guard let service = Self.service(forDevice: device, in: order) else {
            throw SystemCommandError(command: "networksetup -listnetworkserviceorder", result: CommandResult(status: 1, stderr: "no service for \(device)"))
        }
        return service
    }

    public func snapshot(service: String) throws -> ProxySnapshot {
        ProxySnapshot(
            service: service,
            web: Self.endpoint(from: try runner.check(Self.networksetup, ["-getwebproxy", service]).stdout),
            secureWeb: Self.endpoint(from: try runner.check(Self.networksetup, ["-getsecurewebproxy", service]).stdout)
        )
    }

    /// Enables both proxies for `service` and returns what they were before.
    @discardableResult
    public func enable(host: String, port: Int, service: String) throws -> ProxySnapshot {
        let previous = try snapshot(service: service)
        try runner.check(Self.networksetup, ["-setwebproxy", service, host, String(port)])
        try runner.check(Self.networksetup, ["-setsecurewebproxy", service, host, String(port)])
        return previous
    }

    public func restore(_ snapshot: ProxySnapshot) throws {
        try apply(snapshot.web, flag: "-setwebproxy", state: "-setwebproxystate", service: snapshot.service)
        try apply(snapshot.secureWeb, flag: "-setsecurewebproxy", state: "-setsecurewebproxystate", service: snapshot.service)
    }

    private func apply(_ endpoint: ProxyEndpoint, flag: String, state: String, service: String) throws {
        if endpoint.enabled, !endpoint.host.isEmpty {
            try runner.check(Self.networksetup, [flag, service, endpoint.host, String(endpoint.port)])
        } else {
            try runner.check(Self.networksetup, [state, service, "off"])
        }
    }

    // MARK: Parsing

    static func value(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key { return parts[1] }
        }
        return nil
    }

    static func endpoint(from output: String) -> ProxyEndpoint {
        ProxyEndpoint(
            enabled: value(of: "Enabled", in: output) == "Yes",
            host: value(of: "Server", in: output) ?? "",
            port: Int(value(of: "Port", in: output) ?? "") ?? 0
        )
    }

    /// Parses `networksetup -listnetworkserviceorder`:
    /// `(1) Wi-Fi` followed by `(Hardware Port: Wi-Fi, Device: en0)`.
    static func service(forDevice device: String, in output: String) -> String? {
        var lastName: String?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("("), let close = line.firstIndex(of: ")"), line[line.index(after: line.startIndex)..<close].allSatisfy(\.isNumber) {
                lastName = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            } else if line.contains("Device: \(device))") {
                return lastName
            }
        }
        return nil
    }
}

/// Remembers the pre-Proxio settings on disk so a later invocation (or a crash recovery) can restore them.
public struct ProxySnapshotStore: Sendable {
    public let url: URL

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Proxio/system-proxy-snapshot.json")) {
        self.url = url
    }

    public func load() -> ProxySnapshot? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ProxySnapshot.self, from: $0) }
    }

    public func save(_ snapshot: ProxySnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}
