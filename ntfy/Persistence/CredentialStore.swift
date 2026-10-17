import Foundation
import Security

/// Minimal string storage keyed by service and account, so `CredentialStore` can be tested
/// against an in-memory fake instead of the real Keychain.
protocol KeychainStoring {
    func string(service: String, account: String) throws -> String?
    func set(_ value: String, service: String, account: String) throws
    func remove(service: String, account: String) throws
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Generic-password items in an access group shared by the app and the NSE. Items are readable
/// after first unlock (the NSE fetches messages while the device is locked) and are never
/// synchronized to iCloud Keychain.
struct SystemKeychain: KeychainStoring {
    /// An app group identifier is a valid keychain access group, so the app group both targets
    /// already have doubles as the shared keychain group.
    let accessGroup: String

    func string(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    func set(_ value: String, service: String, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let query = baseQuery(service: service, account: account)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    func remove(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// Used by in-memory stores (previews) and tests.
final class InMemoryKeychain: KeychainStoring {
    private var items: [String: String] = [:]
    private let lock = NSLock()

    func string(service: String, account: String) throws -> String? {
        lock.withLock { items[key(service, account)] }
    }

    func set(_ value: String, service: String, account: String) throws {
        lock.withLock { items[key(service, account)] = value }
    }

    func remove(service: String, account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: key(service, account)) }
    }

    private func key(_ service: String, _ account: String) -> String {
        "\(service)\u{0}\(account)"
    }
}

/// Stores the secret half of a user (password or access token) in the Keychain, keyed by the
/// user's normalized base URL. The username stays in Core Data.
struct CredentialStore {
    static let passwordService = "ntfy.password"
    static let tokenService = "ntfy.token"

    private let tag = "CredentialStore"
    let keychain: KeychainStoring

    func token(baseUrl: String) -> String? {
        nonEmpty(read(service: Self.tokenService, baseUrl: baseUrl))
    }

    func password(baseUrl: String) -> String? {
        nonEmpty(read(service: Self.passwordService, baseUrl: baseUrl))
    }

    /// Removes the other kind of secret, then saves this one, so a user has either a password or
    /// a token. Throws if the secret could not be written; the caller then keeps it in Core Data.
    func save(_ credentials: UserCredentials, baseUrl: String) throws {
        switch credentials {
        case .basic(_, let password):
            removeQuietly(service: Self.tokenService, baseUrl: baseUrl)
            try keychain.set(password, service: Self.passwordService, account: baseUrl)
        case .token(let token):
            removeQuietly(service: Self.passwordService, baseUrl: baseUrl)
            try keychain.set(token, service: Self.tokenService, account: baseUrl)
        }
    }

    func delete(baseUrl: String) {
        removeQuietly(service: Self.passwordService, baseUrl: baseUrl)
        removeQuietly(service: Self.tokenService, baseUrl: baseUrl)
    }

    /// Copies credentials that are still in Core Data into the Keychain. Returns true only once
    /// the Keychain holds exactly that secret, i.e. when the Core Data copy can safely be cleared.
    func migrate(_ credentials: UserCredentials, baseUrl: String) -> Bool {
        do {
            try save(credentials, baseUrl: baseUrl)
            switch credentials {
            case .basic(_, let password):
                return try keychain.string(service: Self.passwordService, account: baseUrl) == password
            case .token(let token):
                return try keychain.string(service: Self.tokenService, account: baseUrl) == token
            }
        } catch {
            Log.w(tag, "Cannot move credentials to Keychain, keeping them in Core Data for now", error)
            return false
        }
    }

    private func read(service: String, baseUrl: String) -> String? {
        do {
            return try keychain.string(service: service, account: baseUrl)
        } catch {
            Log.w(tag, "Cannot read \(service) from Keychain", error)
            return nil
        }
    }

    private func removeQuietly(service: String, baseUrl: String) {
        do {
            try keychain.remove(service: service, account: baseUrl)
        } catch {
            Log.w(tag, "Cannot remove \(service) from Keychain", error)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
