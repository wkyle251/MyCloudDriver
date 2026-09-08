import Foundation
import Security

enum LegacyKeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Legacy Keychain error \(status)"
        case .invalidData:
            return "The legacy Keychain session is not valid UTF-8."
        }
    }
}

/// Read/delete support used only to migrate builds older than 1.7.0 away from
/// Keychain storage. New credentials are never written to Keychain.
enum LegacyKeychainStore {
    private static let service = "com.wky.PikPakDownloader"
    private static let account = "pikpak-refresh-token"

    static func loadToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw LegacyKeychainStoreError.unexpectedStatus(status)
        }
        guard
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            throw LegacyKeychainStoreError.invalidData
        }
        return token
    }

    static func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LegacyKeychainStoreError.unexpectedStatus(status)
        }
    }
}
