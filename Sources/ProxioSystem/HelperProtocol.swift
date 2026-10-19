import Foundation

public enum ProxioHelperConstants {
    public static let machServiceName = "dev.proxio.helper"
    public static let launchDaemonPlist = "dev.proxio.helper.plist"
    public static let appIdentifier = "dev.proxio.app"
    public static let protocolVersion = 1
}

/// What the root helper offers over XPC. It can only point the HTTP/HTTPS proxy of a network service at
/// 127.0.0.1 and put a previous setting back; it never runs arbitrary commands for the caller.
@objc public protocol ProxioHelperProtocol {
    func protocolVersion(reply: @escaping (Int) -> Void)
    /// Reply: the previous settings (JSON-encoded `ProxySnapshot`), or an error message.
    func enableProxy(port: Int, service: String, reply: @escaping (Data?, String?) -> Void)
    /// Reply: nil on success, or an error message.
    func restoreProxy(snapshot: Data, reply: @escaping (String?) -> Void)
}

/// Checks everything that crosses the XPC boundary before the helper acts on it.
public enum HelperValidator {
    public static func isValid(port: Int) -> Bool { (1...65535).contains(port) }

    public static func isKnown(service: String, in services: [String]) -> Bool { services.contains(service) }

    /// Hosts in a snapshot are written back with `networksetup`, so only plain host or IP characters are allowed.
    public static func isPlainHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && host.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || ".-:_".unicodeScalars.contains($0))
        }
    }

    public static func isValid(_ snapshot: ProxySnapshot, services: [String]) -> Bool {
        guard isKnown(service: snapshot.service, in: services) else { return false }
        for endpoint in [snapshot.web, snapshot.secureWeb] {
            guard (0...65535).contains(endpoint.port) else { return false }
            if endpoint.enabled && !isPlainHost(endpoint.host) { return false }
            if !endpoint.host.isEmpty && !isPlainHost(endpoint.host) { return false }
        }
        return true
    }

    /// Parses `networksetup -listallnetworkservices`: a notice line first, disabled services start with `*`.
    public static func services(fromListing output: String) -> [String] {
        output.split(separator: "\n").dropFirst().map { String($0) }.filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    /// Code-signing requirement for XPC clients: the Proxio app, signed by the same team as the helper.
    public static func clientRequirement(teamIdentifier: String) -> String? {
        guard !teamIdentifier.isEmpty, teamIdentifier.unicodeScalars.allSatisfy({ $0.value < 128 && CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return "anchor apple generic and identifier \"\(ProxioHelperConstants.appIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
