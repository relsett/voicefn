import Foundation
import LocalAuthentication
import Security

protocol OpenRouterCredentialStore {
    func containsKey() throws -> Bool
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

struct KeychainStore: OpenRouterCredentialStore {
    private let service = "app.voicemacro.openrouter"
    private let account = "api-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func containsKey() throws -> Bool {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Startup only checks existence. It must not retrieve the secret or show authentication UI.
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw StoreError(status: status) }
        return true
    }

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw StoreError(status: status)
        }
        return key
    }

    func save(_ key: String) throws {
        guard !key.isEmpty else { throw StoreError(status: errSecParam) }
        let update = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StoreError(status: status) }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError(status: addStatus) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError(status: status)
        }
    }

    struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { String(localized: "Couldn’t open the macOS Keychain (\(status)).") }
    }
}
