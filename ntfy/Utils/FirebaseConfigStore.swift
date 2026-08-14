import Foundation
import FirebaseCore

/// Persists a user-imported `GoogleService-Info.plist` so Firebase can be configured against the
/// user's own Firebase project instead of a project bundled with the app. Stored in the shared app
/// group container (like `AttachmentFileStore`), since it's a durable file rather than a small
/// key/value setting.
enum FirebaseConfigStore {
    private static let directoryName = "firebase"
    private static let fileName = "GoogleService-Info.plist"

    /// Firebase raises an uncatchable `NSException` on `FirebaseApp.configure(options:)` if
    /// `GOOGLE_APP_ID` doesn't match this shape, which would otherwise crash-loop the app on every
    /// launch after an import. Every plist downloaded from an actual Firebase console satisfies this.
    private static let googleAppIDPattern = #"^\d+:\d+:ios:[0-9a-fA-F]+$"#

    private static let requiredKeys = ["API_KEY", "GCM_SENDER_ID", "PROJECT_ID", "GOOGLE_APP_ID"]

    struct ConfigSummary {
        let projectID: String?
        let bundleID: String?
        let bundleIDMismatch: Bool
    }

    enum ImportError: LocalizedError {
        case invalidPlist
        case missingRequiredKeys
        case invalidGoogleAppIDFormat

        var errorDescription: String? {
            switch self {
            case .invalidPlist:
                return "That file isn't a valid property list."
            case .missingRequiredKeys:
                return "That file is missing required Firebase configuration keys."
            case .invalidGoogleAppIDFormat:
                return "That file's GOOGLE_APP_ID doesn't look like a valid Firebase app ID."
            }
        }
    }

    private static var configFileUrl: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)!
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static var isConfigured: Bool {
        FileManager.default.fileExists(atPath: configFileUrl.path)
    }

    static func currentSummary() -> ConfigSummary? {
        guard let dict = NSDictionary(contentsOf: configFileUrl) else { return nil }
        return summary(from: dict)
    }

    @discardableResult
    static func importConfig(from sourceUrl: URL) throws -> ConfigSummary {
        let didAccess = sourceUrl.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceUrl.stopAccessingSecurityScopedResource()
            }
        }

        guard let dict = NSDictionary(contentsOf: sourceUrl) else {
            throw ImportError.invalidPlist
        }
        guard requiredKeys.allSatisfy({ (dict[$0] as? String)?.isEmpty == false }) else {
            throw ImportError.missingRequiredKeys
        }
        guard
            let googleAppID = dict["GOOGLE_APP_ID"] as? String,
            googleAppID.range(of: googleAppIDPattern, options: .regularExpression) != nil
        else {
            throw ImportError.invalidGoogleAppIDFormat
        }

        let directory = configFileUrl.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: configFileUrl)
        try FileManager.default.copyItem(at: sourceUrl, to: configFileUrl)

        return summary(from: dict)
    }

    static func removeConfig() {
        try? FileManager.default.removeItem(at: configFileUrl)
    }

    static func loadOptions() -> FirebaseOptions? {
        guard isConfigured else { return nil }
        return FirebaseOptions(contentsOfFile: configFileUrl.path)
    }

    private static func summary(from dict: NSDictionary) -> ConfigSummary {
        let bundleID = dict["BUNDLE_ID"] as? String
        return ConfigSummary(
            projectID: dict["PROJECT_ID"] as? String,
            bundleID: bundleID,
            bundleIDMismatch: bundleID != nil && bundleID != Bundle.main.bundleIdentifier
        )
    }
}
