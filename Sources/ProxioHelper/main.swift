import Foundation
import Security
import ProxioSystem

// Root launch daemon (registered with SMAppService from the app). It only exposes `ProxioHelperProtocol`:
// set the HTTP/HTTPS proxy of a network service to 127.0.0.1:<port>, and restore a previous setting.
// Connections are accepted only from the Proxio app signed by the same team as this helper; an ad-hoc
// signed helper has no team, so it accepts nobody.

final class HelperService: NSObject, ProxioHelperProtocol {
    private let proxy = SystemProxy()

    func protocolVersion(reply: @escaping (Int) -> Void) { reply(ProxioHelperConstants.protocolVersion) }

    func enableProxy(port: Int, service: String, reply: @escaping (Data?, String?) -> Void) {
        guard HelperValidator.isValid(port: port) else { return reply(nil, "invalid port") }
        do {
            guard HelperValidator.isKnown(service: service, in: try knownServices()) else { return reply(nil, "unknown network service") }
            let previous = try proxy.enable(host: "127.0.0.1", port: port, service: service)
            reply(try JSONEncoder().encode(previous), nil)
        } catch { reply(nil, "\(error)") }
    }

    func restoreProxy(snapshot: Data, reply: @escaping (String?) -> Void) {
        do {
            let decoded = try JSONDecoder().decode(ProxySnapshot.self, from: snapshot)
            guard HelperValidator.isValid(decoded, services: try knownServices()) else { return reply("invalid snapshot") }
            try proxy.restore(decoded)
            reply(nil)
        } catch { reply("\(error)") }
    }

    private func knownServices() throws -> [String] {
        HelperValidator.services(fromListing: try proxy.listAllNetworkServices())
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let requirement: String?
    init(requirement: String?) { self.requirement = requirement }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ProxioHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

func ownTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}

let delegate = ListenerDelegate(requirement: ownTeamIdentifier().flatMap(HelperValidator.clientRequirement(teamIdentifier:)))
let listener = NSXPCListener(machServiceName: ProxioHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
