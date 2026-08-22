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

    /// What a reconciliation pass is allowed to do. A single `initialBootstrap: Bool` couldn't
    /// express the account-change case, which needs a third combination of the two independent
    /// decisions ("upload local-only topics?" and "delete local-only topics?").
    enum ReconcileMode {
        /// First pass of this app launch: this device's topics have never been uploaded, so push
        /// them up. Nothing is ever deleted — an empty remote list just means "nothing synced yet".
        case initialBootstrap
        /// The iCloud account itself changed. The new account is authoritative: do NOT upload the
        /// previous account owner's topics into it (this can be a shared or borrowed device), and
        /// do NOT delete local subscriptions either — they simply stop being synced until the user
        /// edits them again. Whatever the new account already has is still downloaded.
        case accountChange
        /// A cross-device change arrived for the already-bootstrapped current account. Local
        /// topics missing from the remote list really were unsubscribed on another device.
        case remoteChange
    }

    private var cancellables: Set<AnyCancellable> = []

    /// Whether an `.initialBootstrap` pass has run against the account that's active *right now*.
    /// Deleting local subscriptions because they're missing from the synced list is only sound
    /// once we know this device's own topics have been pushed into that account's replica.
    /// `.accountChange` clears the local replica, so until the next launch re-bootstraps, a
    /// `.remoteChange` pass would otherwise see every local subscription as "unsubscribed
    /// elsewhere" and delete it, history and all.
    private var hasBootstrappedCurrentAccount = false

    func start() {
        reconcileFromRemote(mode: .initialBootstrap)
        // `.receive(on: DispatchQueue.main)` is load-bearing, not cosmetic. Both notifications
        // below are posted from background threads (NSPersistentStoreRemoteChange from Core Data's
        // history-processing queue, CKAccountChanged from CloudKit's own queue). This target builds
        // in Swift 5 language mode with no strict-concurrency checking, so `@MainActor` on this
        // class only makes the compiler *assume* these sinks run on the main actor — nothing
        // inserts an actual runtime hop. Without this operator, `reconcileFromRemote` would run on
        // the posting thread and touch main-queue-confined Core Data contexts from off-queue.
        NotificationCenter.default
            .publisher(for: TopicSyncStore.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileFromRemote(mode: .remoteChange) }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: TopicSyncStore.accountChangedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileFromRemote(mode: .accountChange) }
            .store(in: &cancellables)
    }

    /// Call after a subscription is created, or its display name/icon changes.
    ///
    /// There is deliberately no "am I currently applying a remote change?" flag here: reconciliation
    /// suppresses the echo explicitly at the call site by passing `syncToCloud: false` to
    /// `SubscriptionManager`/`Store`, which skips calling this method at all. An ambient flag can't
    /// do that job correctly once any of those callers defers its work onto another queue.
    func localSubscriptionDidChange(_ subscription: Subscription) {
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
        TopicSyncStore.shared.remove(baseUrl: baseUrl, topic: topic)
    }

    private func reconcileFromRemote(mode: ReconcileMode) {
        if mode == .accountChange {
            hasBootstrappedCurrentAccount = false
        }

        // An empty `allSyncedTopics()` is ambiguous unless we know the mirrored store is healthy:
        // it means "nothing is synced" only if the store actually loaded. If it didn't (no iCloud
        // account, load failure, an invalid CloudKit model, ...) the same empty list would read as
        // "every topic was unsubscribed elsewhere" and `.remoteChange` would delete every local
        // subscription — along with its attachments and entire notification history. Bail out
        // instead. This matters in practice because `TopicSyncStore`'s remote-change observer is
        // not filtered by store, so an ordinary NSE-delivered push writing to `Store`'s SQLite file
        // also fires `didChangeNotification`.
        guard TopicSyncStore.shared.storeLoadedSuccessfully else {
            Log.w(tag, "TopicSync store is not loaded; skipping reconciliation (mode: \(mode))")
            return
        }

        let synced = TopicSyncStore.shared.allSyncedTopics()
        let local = Store.shared.getSubscriptions() ?? []

        let syncedIdentities = synced.compactMap { syncedTopic -> TopicIdentity? in
            guard let baseUrl = syncedTopic.baseUrl, let topic = syncedTopic.topic else { return nil }
            return TopicIdentity(baseUrl: baseUrl, topic: topic)
        }
        let localIdentities = local.compactMap { subscription -> TopicIdentity? in
            guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return nil }
            return TopicIdentity(baseUrl: baseUrl, topic: topic)
        }

        let remoteOnly = TopicSyncDiff.remoteOnly(local: localIdentities, synced: syncedIdentities)
        let localOnly = TopicSyncDiff.localOnly(local: localIdentities, synced: syncedIdentities)

        // Upload only on the first pass of a launch. On an account change we deliberately do not
        // push the previous account's topics into the new account (see ReconcileMode.accountChange),
        // and on a plain remote change everything local has already been uploaded.
        if mode == .initialBootstrap {
            for identity in localOnly {
                guard let subscription = local.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic }) else { continue }
                TopicSyncStore.shared.upsert(
                    baseUrl: identity.baseUrl,
                    topic: identity.topic,
                    customDisplayName: subscription.customDisplayName,
                    icon: subscription.icon
                )
            }
            hasBootstrappedCurrentAccount = true
        }

        // Remote has it, we don't locally: subscribe through the normal path (so Firebase
        // topic registration happens on this device too), then apply its customization.
        // `syncToCloud: false` everywhere below: these writes are us *applying* a remote change,
        // and must not bounce straight back out to TopicSyncStore as if they were local edits.
        for identity in remoteOnly {
            SubscriptionManager(store: .shared).subscribe(baseUrl: identity.baseUrl, topic: identity.topic, syncToCloud: false)
            guard
                let subscription = Store.shared.getSubscription(baseUrl: identity.baseUrl, topic: identity.topic),
                let syncedTopic = synced.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic })
            else { continue }
            Store.shared.saveDisplayName(for: subscription, name: syncedTopic.customDisplayName, syncToCloud: false)
            Store.shared.saveIcon(for: subscription, icon: syncedTopic.icon, syncToCloud: false)
        }

        // Local has it, remote doesn't, on an already-bootstrapped account: someone unsubscribed on
        // another device, so remove it here too. Only `.remoteChange` may do this — see the mode
        // docs for why bootstrap and account changes must never delete.
        if mode == .remoteChange {
            guard hasBootstrappedCurrentAccount else {
                Log.w(tag, "Skipping \(localOnly.count) local-only deletion(s): the active iCloud account has not been bootstrapped in this session")
                return
            }
            for identity in localOnly {
                guard let subscription = local.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic }) else { continue }
                SubscriptionManager(store: .shared).unsubscribe(subscription, syncToCloud: false)
            }
        }
    }
}
