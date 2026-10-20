import Foundation
import Security

/// Keeps the external proxy password in the login Keychain instead of the rules file.
enum ProxyPasswordStore {
    private static let service = "dev.proxio.external-proxy"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load(account: String) -> String {
        guard !account.isEmpty else { return "" }
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ password: String, account: String) {
        guard !account.isEmpty else { return }
        SecItemDelete(query(account) as CFDictionary)
        guard !password.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
