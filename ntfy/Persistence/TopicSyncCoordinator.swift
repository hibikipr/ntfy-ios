// ntfy/Persistence/TopicSyncCoordinator.swift
import Combine
import Foundation

/// The only component that talks to both `Store` (the app's real Subscription/Notification data)
/// and `TopicSyncStore` (the CloudKit-mirrored topic metadata). Mirrors local subscribe/
/// unsubscribe/rename/icon edits out to `TopicSyncStore`, and reconciles remote changes from
/// other devices back into local `Subscription`s via the normal `SubscriptionManager`/`Store`
/// methods (so e.g. a topic added on another device gets a real Firebase subscription on this
/// device too, not just a bare Core Data row).
@MainActor
final class TopicSyncCoordinator {
    static let shared = TopicSyncCoordinator()
    private let tag = "TopicSyncCoordinator"

    /// Set while applying a remote change, so the `SubscriptionManager`/`Store` calls that
    /// reconciliation makes don't immediately echo back out to `TopicSyncStore` as if they were
    /// new local edits.
    private var isApplyingRemoteChange = false
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        reconcileFromRemote(initialBootstrap: true)
        NotificationCenter.default
            .publisher(for: TopicSyncStore.didChangeNotification)
            .sink { [weak self] _ in self?.reconcileFromRemote(initialBootstrap: false) }
            .store(in: &cancellables)
    }

    /// Call after a subscription is created, or its display name/icon changes.
    func localSubscriptionDidChange(_ subscription: Subscription) {
        guard !isApplyingRemoteChange else { return }
        guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return }
        TopicSyncStore.shared.upsert(
            baseUrl: baseUrl,
            topic: topic,
            customDisplayName: subscription.customDisplayName,
            icon: subscription.icon
        )
    }

    /// Call right before a subscription is deleted (pass values captured before deletion —
    /// the managed object isn't safely readable afterward).
    func localSubscriptionWasRemoved(baseUrl: String, topic: String) {
        guard !isApplyingRemoteChange else { return }
        TopicSyncStore.shared.remove(baseUrl: baseUrl, topic: topic)
    }

    private func reconcileFromRemote(initialBootstrap: Bool) {
        let synced = TopicSyncStore.shared.allSyncedTopics()
        let local = Store.shared.getSubscriptions() ?? []

        let syncedIdentities = synced.map { TopicIdentity(baseUrl: $0.baseUrl ?? "", topic: $0.topic ?? "") }
        let localIdentities = local.map { TopicIdentity(baseUrl: $0.baseUrl ?? "", topic: $0.topic ?? "") }

        let remoteOnly = TopicSyncDiff.remoteOnly(local: localIdentities, synced: syncedIdentities)
        let localOnly = TopicSyncDiff.localOnly(local: localIdentities, synced: syncedIdentities)

        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        // Remote has it, we don't locally: subscribe through the normal path (so Firebase
        // topic registration happens on this device too), then apply its customization.
        for identity in remoteOnly {
            SubscriptionManager(store: .shared).subscribe(baseUrl: identity.baseUrl, topic: identity.topic)
            guard
                let subscription = Store.shared.getSubscription(baseUrl: identity.baseUrl, topic: identity.topic),
                let syncedTopic = synced.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic })
            else { continue }
            Store.shared.saveDisplayName(for: subscription, name: syncedTopic.customDisplayName)
            Store.shared.saveIcon(for: subscription, icon: syncedTopic.icon)
        }

        // Local has it, remote doesn't. First bootstrap pass: never uploaded yet, upload it.
        // Every later pass: someone unsubscribed on another device, remove it locally too.
        for identity in localOnly {
            guard let subscription = local.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic }) else { continue }
            if initialBootstrap {
                localSubscriptionDidChange(subscription)
            } else {
                SubscriptionManager(store: .shared).unsubscribe(subscription)
            }
        }
    }
}
