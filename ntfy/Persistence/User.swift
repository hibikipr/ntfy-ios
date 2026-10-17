import Foundation

extension User {
    /// Secrets live in the Keychain. Core Data only holds one while it waits to be moved there
    /// (an install from before the Keychain, or a Keychain write that failed), and that copy is
    /// then the newer one, so it wins. A token takes precedence over a password.
    func credentials(using credentialStore: CredentialStore) -> UserCredentials? {
        if let coreDataCredentials {
            return coreDataCredentials
        }
        guard let baseUrl else { return nil }
        if let token = credentialStore.token(baseUrl: baseUrl) {
            return .token(token)
        }
        if let password = credentialStore.password(baseUrl: baseUrl) {
            return .basic(username: username ?? "", password: password)
        }
        return nil
    }

    /// Credentials still stored in Core Data, i.e. not yet moved to the Keychain.
    var coreDataCredentials: UserCredentials? {
        if let token, !token.isEmpty {
            return .token(token)
        }
        if let password, !password.isEmpty {
            return .basic(username: username ?? "", password: password)
        }
        return nil
    }
}
