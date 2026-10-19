import Foundation
import Security

/// Where the root CA private key (raw P-256 scalar bytes) lives.
public protocol CAKeyStore: Sendable {
    func load() throws -> Data?
    func save(_ key: Data) throws
    func delete() throws
}

public struct CAKeyStoreError: Error, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus
    public var description: String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(text)"
    }
}

/// Stores the key as a generic password item in the user's login keychain.
public struct KeychainKeyStore: CAKeyStore {
    public let service: String
    public let account: String

    public init(service: String = "dev.proxio.ca", account: String = "root-key") {
        self.service = service
        self.account = account
    }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> Data? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CAKeyStoreError(operation: "read", status: status)
        }
        return data
    }

    public func save(_ key: Data) throws {
        var attributes = identity
        attributes[kSecValueData as String] = key
        attributes[kSecAttrLabel as String] = "Proxio Root CA private key"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: key] as CFDictionary)
            guard update == errSecSuccess else { throw CAKeyStoreError(operation: "update", status: update) }
        } else if status != errSecSuccess {
            throw CAKeyStoreError(operation: "save", status: status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CAKeyStoreError(operation: "delete", status: status)
        }
    }
}

/// Non-persistent store, for tests.
public final class InMemoryKeyStore: CAKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    public init() {}

    public func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; return key }
    public func save(_ key: Data) throws { lock.lock(); self.key = key; lock.unlock() }
    public func delete() throws { lock.lock(); key = nil; lock.unlock() }
}
