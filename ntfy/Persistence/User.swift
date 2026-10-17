import Foundation

extension User {
    /// An access token, when set, takes precedence over the username and password.
    func toCredentials() -> UserCredentials {
        if let token, !token.isEmpty {
            return .token(token)
        }
        return .basic(username: username ?? "?", password: password ?? "?")
    }

    var usesAccessToken: Bool {
        !(token ?? "").isEmpty
    }
}
