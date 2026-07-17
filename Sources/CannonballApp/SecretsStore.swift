import Foundation
import Security

/// Keychain-backed storage for the Tessie credentials entered in Settings.
/// AfterFirstUnlock so background streaming survives a mid-run reboot.
enum SecretsStore {
    private static let service = "com.spencer.cannonball.secrets"

    static var tessieVIN: String? { read("TessieVIN") }
    static var tessieToken: String? { read("TessieToken") }

    static func save(vin: String, token: String) {
        write("TessieVIN", vin)
        write("TessieToken", token)
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
