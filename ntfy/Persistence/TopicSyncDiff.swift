import Foundation

/// A topic's identity for reconciliation purposes — just enough to tell "is this the same
/// topic" between a local `Subscription` and a remote `SyncedTopic`, independent of either
/// entity's Core Data specifics.
struct TopicIdentity: Hashable {
    let baseUrl: String
    let topic: String
}

/// A topic's synced customization fields, keyed by identity — enough to tell "did the name/icon
/// change" between a local `Subscription` and a remote `SyncedTopic`, independent of either
/// entity's Core Data specifics.
struct TopicMetadata: Hashable {
    let identity: TopicIdentity
    let customDisplayName: String?
    let icon: String?
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

    /// Topics present on *both* sides whose synced customDisplayName/icon differs from what's
    /// stored locally — a rename or icon change made on another device that this device hasn't
    /// picked up yet. `remoteOnly`/`localOnly` above are identity-only, so a topic already
    /// shared by both sides falls into neither list no matter how its metadata diverges — that
    /// gap is exactly what let a renamed topic show its old name forever on every other device,
    /// while `TopicSyncStore`'s own mirrored store (and the Settings "Topic Sync: Synced" row,
    /// which only reflects the mirror, not what's been applied to local `Subscription`s) reported
    /// nothing wrong, because nothing about the mirroring itself was broken.
    static func metadataChanged(local: [TopicMetadata], synced: [TopicMetadata]) -> [TopicIdentity] {
        let localByIdentity = Dictionary(uniqueKeysWithValues: local.map { ($0.identity, $0) })
        return synced.compactMap { remote in
            guard let localEntry = localByIdentity[remote.identity] else { return nil }
            let changed = localEntry.customDisplayName != remote.customDisplayName
                || localEntry.icon != remote.icon
            return changed ? remote.identity : nil
        }
    }
}
