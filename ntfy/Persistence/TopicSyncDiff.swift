import Foundation

/// A topic's identity for reconciliation purposes — just enough to tell "is this the same
/// topic" between a local `Subscription` and a remote `SyncedTopic`, independent of either
/// entity's Core Data specifics.
struct TopicIdentity: Hashable {
    let baseUrl: String
    let topic: String
}

/// Pure set-difference logic used by `TopicSyncCoordinator` to reconcile the local
/// `Subscription` list against the CloudKit-synced `SyncedTopic` list. Kept free of Core Data
/// so it's trivially unit-testable.
enum TopicSyncDiff {
    /// Topics present remotely but not locally — this device needs to subscribe to them.
    static func remoteOnly(local: [TopicIdentity], synced: [TopicIdentity]) -> [TopicIdentity] {
        synced.filter { !local.contains($0) }
    }

    /// Topics present locally but not remotely — either "never uploaded yet" (first run) or
    /// "unsubscribed on another device" (later runs). The caller decides which, since this
    /// function has no notion of "first run".
    static func localOnly(local: [TopicIdentity], synced: [TopicIdentity]) -> [TopicIdentity] {
        local.filter { !synced.contains($0) }
    }
}
