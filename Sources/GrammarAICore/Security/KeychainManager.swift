import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Stores secrets as generic passwords in the user's login Keychain.
/// Secrets never touch UserDefaults, files or logs.
///
/// What protects the item: the login Keychain encrypts it at rest, and its
/// access list lets only this app's code signature read it without a prompt.
/// It is an ordinary login-keychain item, so it is part of the user's own
/// Time Machine backups and Migration Assistant transfers.
public struct KeychainManager: Sendable {

    public let service: String

    public init(service: String = "com.kaspidoron.grammarai") {
        self.service = service
    }

    public func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(account: account)

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        // Honoured by the data-protection keychain only. An unsandboxed app
        // without keychain entitlements uses the file-based login keychain,
        // which ignores it - harmless there, correct if that ever changes.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// The Anthropic API key, read from the Keychain at request time.
public struct KeychainAPIKeyProvider: APIKeyProviding {
    public static let account = "anthropic-api-key"

    private let keychain: KeychainManager

    public init(keychain: KeychainManager = KeychainManager()) {
        self.keychain = keychain
    }

    public func apiKey() -> String? {
        keychain.read(account: Self.account)
    }
}
