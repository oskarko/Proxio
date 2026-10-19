import Foundation
import ServiceManagement

public enum HelperState: Sendable, Equatable {
    /// Not built into this app (ad-hoc signed or unbundled build).
    case unavailable
    case notRegistered
    /// Registered; the user still has to allow it in System Settings → Login Items.
    case requiresApproval
    case enabled
}

/// Registers and removes the privileged helper (a launch daemon bundled in the app) with ServiceManagement.
public struct HelperInstaller: Sendable {
    public init() {}

    private var service: SMAppService { SMAppService.daemon(plistName: ProxioHelperConstants.launchDaemonPlist) }

    public var state: HelperState {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    public func register() throws { try service.register() }
    public func unregister() throws { try service.unregister() }
    public func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

public struct HelperError: Error, CustomStringConvertible {
    public let description: String
}

/// Talks to the helper over XPC. A fresh connection per call keeps a crashed helper from wedging the app.
public struct HelperClient: Sendable {
    public init() {}

    public func ping() async -> Bool {
        (try? await call { proxy, done in proxy.protocolVersion { done(.success($0)) } }) == ProxioHelperConstants.protocolVersion
    }

    public func enableProxy(port: Int, service: String) async throws -> ProxySnapshot {
        let data: Data = try await call { proxy, done in
            proxy.enableProxy(port: port, service: service) { data, error in
                if let data { done(.success(data)) } else { done(.failure(HelperError(description: error ?? "helper error"))) }
            }
        }
        return try JSONDecoder().decode(ProxySnapshot.self, from: data)
    }

    public func restoreProxy(_ snapshot: ProxySnapshot) async throws {
        let data = try JSONEncoder().encode(snapshot)
        let _: Bool = try await call { proxy, done in
            proxy.restoreProxy(snapshot: data) { error in
                if let error { done(.failure(HelperError(description: error))) } else { done(.success(true)) }
            }
        }
    }

    private func call<T: Sendable>(_ body: @escaping @Sendable (ProxioHelperProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let connection = NSXPCConnection(machServiceName: ProxioHelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ProxioHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let finish: @Sendable (Result<T, Error>) -> Void = { result in
                if once.claim() { continuation.resume(with: result) }
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ finish(.failure($0)) }) as? ProxioHelperProtocol else {
                return finish(.failure(HelperError(description: "no helper connection")))
            }
            body(proxy, finish)
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool { lock.withLock { defer { used = true }; return !used } }
    }
}
