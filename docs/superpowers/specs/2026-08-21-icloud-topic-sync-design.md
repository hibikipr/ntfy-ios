# iCloud sync for subscribed topics

## Context

The app currently persists subscriptions (`Subscription`: `baseUrl`, `topic`, `customDisplayName`, `icon`, `lastNotificationId`) in a single local Core Data store (`ntfy/Persistence/ntfy.xcdatamodeld`), shared between the main app and the `ntfyNSE` extension via an app-group container. There is no iCloud/CloudKit integration anywhere in the project today (`ntfy/ntfy.entitlements` has only `aps-environment` and the app-group entitlement).

The user wants their subscribed topics to sync live across their own devices via iCloud: subscribing on one device should make the topic appear on another shortly after, and unsubscribing should remove it everywhere. They also want per-topic customizations (`customDisplayName`, `icon`) to sync, so the same topic looks identical on every device. They explicitly do **not** want notification history or saved server users/passwords to sync.

Decided during brainstorming:
- Full CloudKit (via `NSPersistentCloudKitContainer`), not `NSUbiquitousKeyValueStore` — the user chose robustness (per-record conflict handling) over lower setup effort.
- `Subscription` and `Notification` cannot share a CloudKit-synced Core Data configuration: standard Core Data relationships cannot span two different persistent stores/configurations, and CloudKit-backed configurations additionally disallow unique constraints and required relationships (`Subscription.notifications`/`Notification.subscription` has neither problem today, but moving `Subscription` into a synced configuration would force breaking that relationship into a manual string-keyed link, a real migration touching working save/delete/query code). The design below avoids that entirely by keeping the existing store untouched and adding a second, independent, minimal store just for sync.

## Design

### 1. New, independent Core Data model for sync: `TopicSync.xcdatamodeld`

A new `.xcdatamodeld` (sibling to the existing one, e.g. `ntfy/Persistence/TopicSync.xcdatamodeld`) with a single entity, `SyncedTopic`:

```xml
<entity name="SyncedTopic" representedClassName="SyncedTopic" syncable="YES" codeGenerationType="class">
    <attribute name="recordName" attributeType="String"/>
    <attribute name="baseUrl" attributeType="String"/>
    <attribute name="topic" attributeType="String"/>
    <attribute name="customDisplayName" optional="YES" attributeType="String"/>
    <attribute name="icon" optional="YES" attributeType="String"/>
    <attribute name="lastModified" attributeType="Date" usesScalarValueType="NO"/>
    <uniquenessConstraints>
        <uniquenessConstraint>
            <constraint value="recordName"/>
        </uniquenessConstraint>
    </uniquenessConstraints>
</entity>
```

`recordName` is `"\(baseUrl)|\(topic)"` — a stable, deterministic identifier so the same topic always maps to the same CloudKit record regardless of which device created it, which is what makes conflicts resolve per-topic instead of creating duplicates. No relationships at all — this entity is intentionally standalone.

Per CloudKit's Core Data requirements (all attributes optional or defaulted, no required relationships, no unique constraints enforced *by CloudKit itself*): the uniqueness constraint above is enforced locally by this device's own store for de-duplication before export: CloudKit does not support Core Data's `uniquenessConstraints` mechanism, so the model must not rely on it for correctness across devices — `TopicSyncStore.upsert(...)` (below) is what actually guarantees one `SyncedTopic` per topic, by always looking up-then-upsert-by-`recordName` rather than blindly inserting.

### 2. `TopicSyncStore` (`ntfy/Persistence/TopicSyncStore.swift`)

An `NSPersistentCloudKitContainer`-backed stack, shaped like a much smaller version of `Store`:

```swift
final class TopicSyncStore {
    static let shared = TopicSyncStore()
    static let tag = "TopicSyncStore"
    static let didChangeNotification = NSNotification.Name("TopicSyncStore.didChange")

    private let container: NSPersistentCloudKitContainer
    var context: NSManagedObjectContext { container.viewContext }
    private var cancellables: Set<AnyCancellable> = []

    init() {
        container = NSPersistentCloudKitContainer(name: "TopicSync")
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("No persistent store description for TopicSync")
        }
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.victormanuel.ntfy")

        container.loadPersistentStores { _, error in
            if let error {
                Log.e(TopicSyncStore.tag, "Failed to load TopicSync store: \(error.localizedDescription)", error)
            }
        }
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)

        NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .sink { [weak self] _ in
                self?.context.perform { self?.context.refreshAllObjects() }
                NotificationCenter.default.post(name: TopicSyncStore.didChangeNotification, object: self)
            }
            .store(in: &cancellables)
    }

    func allSyncedTopics() -> [SyncedTopic] {
        let request = SyncedTopic.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func upsert(baseUrl: String, topic: String, customDisplayName: String?, icon: String?) {
        context.performAndWait {
            let recordName = "\(baseUrl)|\(topic)"
            let existing = try? fetchByRecordName(recordName)
            let syncedTopic = existing ?? SyncedTopic(context: context)
            syncedTopic.recordName = recordName
            syncedTopic.baseUrl = baseUrl
            syncedTopic.topic = topic
            syncedTopic.customDisplayName = customDisplayName
            syncedTopic.icon = icon
            syncedTopic.lastModified = Date()
            try? context.save()
        }
    }

    func remove(baseUrl: String, topic: String) {
        context.performAndWait {
            guard let syncedTopic = try? fetchByRecordName("\(baseUrl)|\(topic)") else { return }
            context.delete(syncedTopic)
            try? context.save()
        }
    }

    private func fetchByRecordName(_ recordName: String) throws -> SyncedTopic? {
        let request = SyncedTopic.fetchRequest()
        request.predicate = NSPredicate(format: "recordName == %@", recordName)
        return try context.fetch(request).first
    }
}
```

This mirrors the existing `Store`'s remote-change pattern (`NSPersistentStoreRemoteChangeNotificationPostOptionKey` + `.sink` + `refreshAllObjects()`), but additionally enables `NSPersistentHistoryTrackingKey`, which `Store`'s existing setup does not set — history tracking is required for `NSPersistentCloudKitContainer` specifically (unlike the app-group same-device case `Store` handles, CloudKit mirroring needs persistent history to know what to export/import). This does **not** change `Store`'s own setup; it's local to `TopicSyncStore`.

`NSNotification.Name` (not `Notification.Name`) is required here for the same reason it's required in `Store.swift`: this module's `Notification` Core Data entity shadows `Foundation.Notification`.

### 3. `TopicSyncCoordinator` (`ntfy/Persistence/TopicSyncCoordinator.swift`)

The only component that talks to both stores. Owns reconciliation and the reentrancy guard:

```swift
@MainActor
final class TopicSyncCoordinator {
    static let shared = TopicSyncCoordinator()
    private let tag = "TopicSyncCoordinator"
    private var isApplyingRemoteChange = false
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        reconcileFromRemote(initialBootstrap: true)
        NotificationCenter.default
            .publisher(for: TopicSyncStore.didChangeNotification)
            .sink { [weak self] _ in self?.reconcileFromRemote(initialBootstrap: false) }
            .store(in: &cancellables)
    }

    // Called from SubscriptionManager.subscribe/unsubscribe and Store.saveIcon/saveDisplayName.
    func localSubscriptionDidChange(_ subscription: Subscription) {
        guard !isApplyingRemoteChange else { return }
        TopicSyncStore.shared.upsert(
            baseUrl: subscription.baseUrl ?? "",
            topic: subscription.topic ?? "",
            customDisplayName: subscription.customDisplayName,
            icon: subscription.icon
        )
    }

    func localSubscriptionWasRemoved(baseUrl: String, topic: String) {
        guard !isApplyingRemoteChange else { return }
        TopicSyncStore.shared.remove(baseUrl: baseUrl, topic: topic)
    }

    private func reconcileFromRemote(initialBootstrap: Bool) {
        let synced = TopicSyncStore.shared.allSyncedTopics()
        let local = Store.shared.getSubscriptions() ?? []

        let remoteOnly = synced.filter { topic in
            !local.contains { $0.baseUrl == topic.baseUrl && $0.topic == topic.topic }
        }
        let localOnly = local.filter { subscription in
            !synced.contains { $0.baseUrl == subscription.baseUrl && $0.topic == subscription.topic }
        }

        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        // Remote has it, we don't locally: subscribe (through the normal path, so
        // Firebase topic registration happens on this device too), then apply its
        // customDisplayName/icon.
        for topic in remoteOnly {
            SubscriptionManager(store: .shared).subscribe(baseUrl: topic.baseUrl, topic: topic.topic)
            if let subscription = Store.shared.getSubscription(baseUrl: topic.baseUrl, topic: topic.topic) {
                Store.shared.saveDisplayName(for: subscription, name: topic.customDisplayName)
                Store.shared.saveIcon(for: subscription, icon: topic.icon)
            }
        }

        // Local has it, remote doesn't. On the very first bootstrap pass this means
        // "never uploaded yet" — upload it. On every later pass it means "someone
        // unsubscribed on another device" — remove it locally too.
        for subscription in localOnly {
            if initialBootstrap {
                localSubscriptionDidChange(subscription)
            } else {
                SubscriptionManager(store: .shared).unsubscribe(subscription)
            }
        }
    }
}
```

The `isApplyingRemoteChange` flag is the loop guard described in the approved data-flow: applying a remote change calls the same `SubscriptionManager` methods a real local edit would, so without the flag every remote-applied change would immediately re-upsert itself back into `TopicSyncStore`.

Call sites to add (small, additive changes to existing methods — no existing behavior removed):
- `SubscriptionManager.subscribe(baseUrl:topic:)` (`ntfy/Persistence/SubscriptionManager.swift`): after `store.saveSubscription(...)`, call `TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)`.
- `SubscriptionManager.unsubscribe(_:)`: before `store.delete(subscription:)` removes it, call `TopicSyncCoordinator.shared.localSubscriptionWasRemoved(baseUrl:topic:)` (captured before deletion, since the managed object won't be safely readable after).
- `Store.saveIcon(for:icon:)` and `Store.saveDisplayName(for:name:)`: after saving, call `TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)`.
- `AppMain.swift`: call `TopicSyncCoordinator.shared.start()` once at launch, alongside the existing `store`/`iconManager` setup.

### 4. Settings status row

A new `ntfy/Views/Settings/iCloudSyncSettingView.swift`, following the exact status-row pattern already established by `FirebaseConfigView.swift` (Button row showing a status string, e.g. "Synced" / "Not signed into iCloud" / "Sync unavailable", derived from `FileManager.default.ubiquityIdentityToken != nil` plus the container's load state). Wired into `SettingsView.swift` as a new row, likely in the existing "General" section next to `DefaultServerView`.

### 5. Project/entitlement changes

- Add the iCloud capability (CloudKit) to the `ntfy` target in Xcode, creating a CloudKit container (e.g. `iCloud.com.victormanuel.ntfy`) under the Apple Developer account. **This step is on the user** — same as the `FirebaseCore` package dependency and the Critical Alerts entitlement earlier, this requires access to the Apple Developer portal / Xcode's Signing & Capabilities UI that isn't scriptable from here.
- `ntfy/ntfy.entitlements` gains the resulting `com.apple.developer.icloud-services` / `com.apple.developer.icloud-container-identifiers` keys (Xcode writes these automatically when the capability is added).
- New `TopicSync.xcdatamodeld` and the two new Swift files need to be added to the `ntfy` target only (not `ntfyNSE` — the extension has no reason to touch CloudKit sync).

### 6. Account-change handling

Observe `NSPersistentCloudKitContainer`'s CloudKit event notifications (`NSPersistentCloudKitContainer.eventChangedNotification`) for account changes; on detecting a different iCloud account, clear the local `TopicSyncStore` replica and re-run `TopicSyncCoordinator`'s bootstrap reconciliation, so a shared/borrowed device doesn't mix two people's topic lists.

## Out of scope

- No syncing of notification history (`Notification` entity) or saved server users/passwords (`User` entity) — explicitly excluded by the user.
- No UI for resolving sync conflicts — CloudKit/Core Data's default last-write-wins-per-field merge is accepted as sufficient for this lightweight metadata.
- No changes to `ntfyNSE` — it only ever reads local `Subscription` rows already shared via the app group, independent of this feature.
- No public/shared CloudKit database, no sharing topics between different iCloud accounts — private database only, one user's own devices.
- `lastNotificationId` is deliberately not synced — it's local polling bookkeeping, not something meaningful to share across devices.

## Testing

- Unit tests (`ntfyTests`) for `TopicSyncCoordinator`'s diff logic (given a local subscription list and a synced-topic list, what gets added/removed/uploaded) — this is pure logic and can be tested without real CloudKit, by constructing in-memory `Store`/`TopicSyncStore` instances (both already support `inMemory: Bool` / can be adapted to).
- Build check after each change.
- Manual, on-device, required (CloudKit sync cannot be exercised in this environment): subscribe to a topic on device A, confirm it appears on device B within a short delay; unsubscribe on device B, confirm it disappears on device A; rename/change icon on one device, confirm it updates on the other; sign out of iCloud and confirm the app continues to work locally with the Settings row reflecting "Not signed into iCloud".
