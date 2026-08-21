# iCloud Topic Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync the user's subscribed topics (server, topic, display name, icon) live across their own devices via iCloud, without syncing notification history or saved server credentials.

**Architecture:** A second, independent `NSPersistentCloudKitContainer`-backed Core Data stack (`TopicSyncStore`, model `TopicSync.xcdatamodeld`, single entity `SyncedTopic`) mirrors topic metadata to the user's private CloudKit database. A `TopicSyncCoordinator` is the only component that talks to both this store and the existing local `Store`/`Subscription` — it pushes local subscribe/unsubscribe/rename/icon edits into `TopicSyncStore`, and reconciles remote changes back into local `Subscription` rows via the app's existing `SubscriptionManager`/`Store` methods. The existing `Subscription`↔`Notification` relationship and store are completely untouched.

**Tech Stack:** Swift, SwiftUI, Core Data, `NSPersistentCloudKitContainer`, CloudKit (private database only), Combine, XCTest.

## Global Constraints

- Sync scope: `Subscription`'s `baseUrl`, `topic`, `customDisplayName`, `icon` only. Never sync `Notification` (history) or `User` (server credentials). `lastNotificationId` is local bookkeeping and must not be synced.
- Private CloudKit database only — no public/shared database, no cross-account sharing.
- `ntfyNSE` (the notification service extension) gets zero changes — it only reads local `Subscription` rows via the existing app-group store.
- The new `TopicSync.xcdatamodeld`, `TopicSyncStore.swift`, and `TopicSyncCoordinator.swift` must be added to the `ntfy` target only, not `ntfyNSE`.
- `NSNotification.Name` (not `Notification.Name`) must be used for any custom notification name declared in `ntfy/Persistence/` — this module's `Notification` Core Data entity shadows `Foundation.Notification`, so `Notification.Name(...)` fails to compile (this bit `Store.didHardRefreshNotification` earlier in this project's history).
- Spec reference: `docs/superpowers/specs/2026-08-21-icloud-topic-sync-design.md`.

---

### Task 1: `TopicSyncDiff` — pure reconciliation logic + unit tests

No dependencies on anything else in this plan — pure Swift, fully unit-testable, do this first.

**Files:**
- Create: `ntfy/Persistence/TopicSyncDiff.swift`
- Test: `ntfyTests/TopicSyncDiffTests.swift`

**Interfaces:**
- Produces: `struct TopicIdentity: Hashable { let baseUrl: String; let topic: String }`, `enum TopicSyncDiff { static func remoteOnly(local: [TopicIdentity], synced: [TopicIdentity]) -> [TopicIdentity]; static func localOnly(local: [TopicIdentity], synced: [TopicIdentity]) -> [TopicIdentity] }`. Later tasks (Task 6) convert their real `Subscription`/`SyncedTopic` arrays into `[TopicIdentity]` to call these.

- [ ] **Step 1: Write the failing tests**

```swift
// ntfyTests/TopicSyncDiffTests.swift
import XCTest
@testable import ntfy

final class TopicSyncDiffTests: XCTestCase {
    func testRemoteOnlyReturnsItemsInSyncedButNotLocal() {
        let local = [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")]
        let synced = [
            TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts"),
            TopicIdentity(baseUrl: "https://ntfy.sh", topic: "backups")
        ]
        let result = TopicSyncDiff.remoteOnly(local: local, synced: synced)
        XCTAssertEqual(result, [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "backups")])
    }

    func testLocalOnlyReturnsItemsInLocalButNotSynced() {
        let local = [
            TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts"),
            TopicIdentity(baseUrl: "https://ntfy.sh", topic: "backups")
        ]
        let synced = [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")]
        let result = TopicSyncDiff.localOnly(local: local, synced: synced)
        XCTAssertEqual(result, [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "backups")])
    }

    func testIdenticalSetsProduceNoDifferences() {
        let identity = TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")
        XCTAssertTrue(TopicSyncDiff.remoteOnly(local: [identity], synced: [identity]).isEmpty)
        XCTAssertTrue(TopicSyncDiff.localOnly(local: [identity], synced: [identity]).isEmpty)
    }

    func testEmptyLocalTreatsEverySyncedItemAsRemoteOnly() {
        let synced = [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")]
        XCTAssertEqual(TopicSyncDiff.remoteOnly(local: [], synced: synced), synced)
        XCTAssertTrue(TopicSyncDiff.localOnly(local: [], synced: synced).isEmpty)
    }

    func testSameTopicDifferentServerAreNotEqual() {
        let local = [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")]
        let synced = [TopicIdentity(baseUrl: "https://example.com", topic: "alerts")]
        XCTAssertEqual(TopicSyncDiff.remoteOnly(local: local, synced: synced), synced)
        XCTAssertEqual(TopicSyncDiff.localOnly(local: local, synced: synced), local)
    }
}
```

This project's existing test file (`ntfyTests/MessageParsingTests.swift`) uses XCTest (`import XCTest`, `final class ...: XCTestCase`, `func testX()`, `XCTAssertEqual`/`XCTAssertTrue`) — match that convention exactly, not Swift Testing's `@Test`/`#expect` macros.

- [ ] **Step 2: Run the tests to verify they fail**

Use the `RunAllTests` / `RunSomeTests` Xcode MCP tool (or Xcode's Test navigator). Expected: build failure — `TopicIdentity`/`TopicSyncDiff` don't exist yet.

- [ ] **Step 3: Create `TopicSyncDiff.swift` with the minimal implementation**

```swift
// ntfy/Persistence/TopicSyncDiff.swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Use `RunAllTests`. Expected: all 5 new tests pass, plus the existing 20 tests in `MessageParsingTests.swift` still pass (25 total).

- [ ] **Step 5: Build check**

Use `BuildProject`. Expected: succeeds, no warnings (check via `GetBuildLog` with `severity: "warning"`).

- [ ] **Step 6: Commit**

```bash
git add ntfy/Persistence/TopicSyncDiff.swift ntfyTests/TopicSyncDiffTests.swift
git commit -m "Add pure diff logic for reconciling local subscriptions against synced topics"
```

---

### Task 2: Manual setup — create the `TopicSync` Core Data model skeleton (user-performed)

Core Data's versioned model wrapper (`.xcdatamodeld`) has project-file bookkeeping (a "current version" pointer) that Xcode's New File flow sets up correctly; recreating that by hand via raw file writes is a real risk (this exact project already hit surprises this session with the file-creation tool over-applying target membership on plain Swift files — an `.xcdatamodeld` is a more complex wrapper package, not worth risking). Do this step in Xcode itself:

- [ ] **Step 1: In Xcode, right-click the `Persistence` group → New File… → (under Core Data) Data Model.**

Name it `TopicSync`. Save it in `ntfy/Persistence/`, next to the existing `ntfy.xcdatamodeld`. Make sure it's added to the **ntfy** target only (uncheck `ntfyNSE` if Xcode's dialog shows target checkboxes).

- [ ] **Step 2: Build check**

Use `BuildProject`. Expected: succeeds (an empty data model with no entities is valid).

- [ ] **Step 3: Report back the exact file path Xcode created**

It will be `ntfy/Persistence/TopicSync.xcdatamodeld/TopicSync.xcdatamodel/contents` (or similar versioned subfolder name — confirm the actual path with `find ntfy/Persistence/TopicSync.xcdatamodeld -name contents`). Task 4 edits this file directly.

- [ ] **Step 4: Commit**

```bash
git add ntfy/Persistence/TopicSync.xcdatamodeld ntfy.xcodeproj/project.pbxproj
git commit -m "Add empty TopicSync Core Data model skeleton"
```

---

### Task 3: Manual setup — enable iCloud/CloudKit capability (user-performed)

This requires Apple Developer account access and can't be scripted from here — same category of step as adding the `FirebaseCore` package dependency or the Critical Alerts entitlement earlier in this project.

- [ ] **Step 1: In Xcode, select the `ntfy` target → Signing & Capabilities → + Capability → iCloud.**

Check **CloudKit**. Under Containers, create a new container (suggested identifier: `iCloud.com.victormanuel.ntfy`, matching the app's existing `group.com.victormanuel.ntfy` app-group naming convention — adjust if Xcode suggests a different available identifier).

- [ ] **Step 2: Confirm `ntfy/ntfy.entitlements` was updated**

```bash
cat ntfy/ntfy.entitlements
```

Expected: it now contains `com.apple.developer.icloud-services` (with `CloudKit`) and `com.apple.developer.icloud-container-identifiers` (with the container identifier chosen above), alongside the existing `aps-environment` and `com.apple.security.application-groups` keys.

- [ ] **Step 3: Record the container identifier**

Whatever identifier Xcode assigned, it's needed verbatim in Task 5's `NSPersistentCloudKitContainerOptions(containerIdentifier:)` call — confirm it before proceeding.

- [ ] **Step 4: Build check, then commit**

```bash
git add ntfy/ntfy.entitlements ntfy.xcodeproj/project.pbxproj
git commit -m "Enable iCloud CloudKit capability for topic sync"
```

---

### Task 4: Define the `SyncedTopic` entity

**Files:**
- Modify: `ntfy/Persistence/TopicSync.xcdatamodeld/TopicSync.xcdatamodel/contents` (exact path confirmed in Task 2, Step 3)

**Interfaces:**
- Produces: Core Data entity `SyncedTopic` with attributes `recordName: String`, `baseUrl: String`, `topic: String`, `customDisplayName: String?`, `icon: String?`, `lastModified: Date`. Xcode auto-generates the `SyncedTopic` Swift class at build time (`codeGenerationType="class"`, same as every entity in the existing `ntfy.xcdatamodeld`) — no manual class file needed. Task 5 uses `SyncedTopic.fetchRequest()` and its properties directly.

- [ ] **Step 1: Read the current (empty) model contents**

```bash
cat "ntfy/Persistence/TopicSync.xcdatamodeld/TopicSync.xcdatamodel/contents"
```

- [ ] **Step 2: Replace the `<model ...> ... </model>` body to add the entity**

Keep whatever `<model ...>` opening tag attributes Xcode generated (version numbers etc. — don't hand-edit those), and insert this entity plus an `<elements>` positioning block, mirroring the exact structure used in `ntfy/Persistence/ntfy.xcdatamodeld/Model.xcdatamodel/contents`:

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

and, right before the closing `</model>` tag, an elements block (adjust `positionX`/`positionY` to any non-overlapping values — exact placement doesn't matter functionally):

```xml
<elements>
    <element name="SyncedTopic" positionX="-63" positionY="-18" width="128" height="134"/>
</elements>
```

- [ ] **Step 3: Build check**

Use `BuildProject`. Expected: succeeds. If it fails with a Core Data model validation error, check that every attribute has a value for `attributeType` and that `uniquenessConstraints` syntax matches the existing model file exactly.

- [ ] **Step 4: Commit**

```bash
git add "ntfy/Persistence/TopicSync.xcdatamodeld"
git commit -m "Define SyncedTopic entity for iCloud topic sync"
```

---

### Task 5: `TopicSyncStore` — the CloudKit-backed Core Data stack

**Files:**
- Create: `ntfy/Persistence/TopicSyncStore.swift`
- Test: `ntfyTests/TopicSyncStoreTests.swift`

**Interfaces:**
- Consumes: `SyncedTopic` (Task 4), container identifier from Task 3.
- Produces: `final class TopicSyncStore { static let shared: TopicSyncStore; static let didChangeNotification: NSNotification.Name; init(inMemory: Bool = false); func allSyncedTopics() -> [SyncedTopic]; func upsert(baseUrl: String, topic: String, customDisplayName: String?, icon: String?); func remove(baseUrl: String, topic: String) }`. Task 6 (`TopicSyncCoordinator`) calls all of these on `TopicSyncStore.shared`; Task 9 (Settings row) reads sync status from it.

- [ ] **Step 1: Write the failing tests (CRUD against an in-memory store — no real CloudKit needed for this)**

```swift
// ntfyTests/TopicSyncStoreTests.swift
import XCTest
@testable import ntfy

final class TopicSyncStoreTests: XCTestCase {
    func testUpsertThenFetchReturnsTheSameTopic() {
        let store = TopicSyncStore(inMemory: true)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "alerts", customDisplayName: "Alerts", icon: "🔔")

        let topics = store.allSyncedTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.baseUrl, "https://ntfy.sh")
        XCTAssertEqual(topics.first?.topic, "alerts")
        XCTAssertEqual(topics.first?.customDisplayName, "Alerts")
        XCTAssertEqual(topics.first?.icon, "🔔")
    }

    func testUpsertTwiceForSameTopicUpdatesInPlaceInsteadOfDuplicating() {
        let store = TopicSyncStore(inMemory: true)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "alerts", customDisplayName: "Alerts", icon: nil)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "alerts", customDisplayName: "Renamed", icon: "🔔")

        let topics = store.allSyncedTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.customDisplayName, "Renamed")
        XCTAssertEqual(topics.first?.icon, "🔔")
    }

    func testRemoveDeletesTheMatchingTopicOnly() {
        let store = TopicSyncStore(inMemory: true)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "alerts", customDisplayName: nil, icon: nil)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "backups", customDisplayName: nil, icon: nil)

        store.remove(baseUrl: "https://ntfy.sh", topic: "alerts")

        let topics = store.allSyncedTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.topic, "backups")
    }

    func testRemoveOfNonexistentTopicDoesNothing() {
        let store = TopicSyncStore(inMemory: true)
        store.remove(baseUrl: "https://ntfy.sh", topic: "does-not-exist")
        XCTAssertTrue(store.allSyncedTopics().isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Expected: build failure — `TopicSyncStore` doesn't exist yet.

- [ ] **Step 3: Create `TopicSyncStore.swift`**

```swift
// ntfy/Persistence/TopicSyncStore.swift
import Combine
import CoreData

/// A second, independent Core Data stack, separate from `Store`, that mirrors subscribed-topic
/// metadata (server, topic, display name, icon) to the user's private CloudKit database. Kept
/// completely separate from `Store`'s `Subscription`/`Notification` model: Core Data relationships
/// can't span two CloudKit configurations, and this app explicitly does not want notification
/// history or credentials syncing to iCloud. See
/// docs/superpowers/specs/2026-08-21-icloud-topic-sync-design.md for the full rationale.
final class TopicSyncStore {
    static let shared = TopicSyncStore()
    static let tag = "TopicSyncStore"
    /// Posted whenever a remote (cross-device) change is detected. `TopicSyncCoordinator`
    /// listens for this to trigger reconciliation.
    static let didChangeNotification = NSNotification.Name("TopicSyncStore.didChange")

    private static let containerIdentifier = "iCloud.com.victormanuel.ntfy" // must match Task 3's container

    private let container: NSPersistentCloudKitContainer
    var context: NSManagedObjectContext { container.viewContext }
    private var cancellables: Set<AnyCancellable> = []

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "TopicSync")

        if inMemory {
            let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
            // In-memory stores can't mirror to CloudKit — this path exists purely for fast,
            // deterministic unit tests of the CRUD methods below.
            description.cloudKitContainerOptions = nil
            container.persistentStoreDescriptions = [description]
        } else if let description = container.persistentStoreDescriptions.first {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerIdentifier)
        }

        container.loadPersistentStores { _, error in
            if let error {
                Log.e(TopicSyncStore.tag, "Failed to load TopicSync store: \(error.localizedDescription)", error)
            }
        }
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)

        guard !inMemory else { return }
        NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .sink { [weak self] _ in
                guard let self else { return }
                self.context.perform { self.context.refreshAllObjects() }
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
            let syncedTopic = (try? fetchByRecordName(recordName)) ?? SyncedTopic(context: context)
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

- [ ] **Step 4: Run the tests to verify they pass**

Expected: all 4 new tests pass, all prior tests still pass (29 total).

- [ ] **Step 5: Build check for warnings**

Use `BuildProject` then `GetBuildLog` with `severity: "warning"`. Expected: zero warnings. (Watch specifically for the `Notification`/`NSNotification` name-collision warning/error this project hit before — `didChangeNotification` above already uses `NSNotification.Name`, not `Notification.Name`.)

- [ ] **Step 6: Commit**

```bash
git add ntfy/Persistence/TopicSyncStore.swift ntfyTests/TopicSyncStoreTests.swift
git commit -m "Add TopicSyncStore, a CloudKit-backed Core Data stack for synced topic metadata"
```

---

### Task 6: `TopicSyncCoordinator` — reconciliation between `TopicSyncStore` and local `Subscription`s

**Files:**
- Create: `ntfy/Persistence/TopicSyncCoordinator.swift`

**Interfaces:**
- Consumes: `TopicIdentity`, `TopicSyncDiff.remoteOnly`/`.localOnly` (Task 1); `TopicSyncStore.shared.allSyncedTopics()`/`.upsert(...)`/`.remove(...)` (Task 5); `Store.shared.getSubscriptions() -> [Subscription]?`, `Store.shared.getSubscription(baseUrl:topic:) -> Subscription?`, `Store.shared.saveDisplayName(for:name:)`, `Store.shared.saveIcon(for:icon:)` (existing `Store.swift`); `SubscriptionManager(store:).subscribe(baseUrl:topic:)`/`.unsubscribe(_:)` (existing `SubscriptionManager.swift`).
- Produces: `@MainActor final class TopicSyncCoordinator { static let shared: TopicSyncCoordinator; func start(); func localSubscriptionDidChange(_ subscription: Subscription); func localSubscriptionWasRemoved(baseUrl: String, topic: String) }`. Tasks 7 and 8 call `localSubscriptionDidChange`/`localSubscriptionWasRemoved`; Task 9 (AppMain) calls `start()`.

No new automated tests in this task — `reconcileFromRemote` drives real `SubscriptionManager`/`Store.shared` side effects (Firebase topic registration, Core Data writes against the live shared store), which isn't something to exercise against the shared singleton in a unit test. Its core decision logic is already covered by Task 1's `TopicSyncDiff` tests; this task is build-checked and covered by Task 11's manual on-device verification.

- [ ] **Step 1: Create `TopicSyncCoordinator.swift`**

```swift
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
```

- [ ] **Step 2: Build check**

Use `BuildProject`. Expected: succeeds. `SubscriptionManager` is a `struct` with a memberwise `init(store:)` (see `ntfy/Persistence/SubscriptionManager.swift`), so `SubscriptionManager(store: .shared)` must resolve — if it doesn't compile, check `Store.shared`'s type matches what `SubscriptionManager.store` expects.

- [ ] **Step 3: Run the full test suite to confirm nothing broke**

Expected: same pass count as after Task 5 (this task adds no new tests).

- [ ] **Step 4: Commit**

```bash
git add ntfy/Persistence/TopicSyncCoordinator.swift
git commit -m "Add TopicSyncCoordinator to reconcile local subscriptions with synced topics"
```

---

### Task 7: Wire the coordinator into `SubscriptionManager`

**Files:**
- Modify: `ntfy/Persistence/SubscriptionManager.swift`

**Interfaces:**
- Consumes: `TopicSyncCoordinator.shared.localSubscriptionDidChange(_:)`, `.localSubscriptionWasRemoved(baseUrl:topic:)` (Task 6).

The current `unsubscribe(_:)` only captures `baseUrl`/`topic` into local constants *inside* the `if let baseUrl = ..., let topic = ..., FirebaseApp.app() != nil` guard used for the Firebase unsubscribe call — meaning if Firebase isn't configured (see `FirebaseConfigStore`/the BYO-Firebase feature earlier in this project), that whole block is skipped and `baseUrl`/`topic` are never captured. The sync call must not depend on Firebase being configured, so capture them independently.

- [ ] **Step 1: Read the current file**

```bash
cat -n ntfy/Persistence/SubscriptionManager.swift
```

Confirm the current shape of `subscribe(baseUrl:topic:)` and `unsubscribe(_:)` matches what's described below before editing — if it's drifted, adapt the edit to the actual current code rather than blindly pattern-matching this snippet.

- [ ] **Step 2: Add the sync call to `subscribe(baseUrl:topic:)`**

Find:
```swift
        let subscription = store.saveSubscription(baseUrl: normalizedBaseUrl, topic: topic)
        Task {
            await poll(subscription, notifyOnNewMessages: false)
        }
```

Replace with:
```swift
        let subscription = store.saveSubscription(baseUrl: normalizedBaseUrl, topic: topic)
        TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)
        Task {
            await poll(subscription, notifyOnNewMessages: false)
        }
```

- [ ] **Step 3: Add the sync call to `unsubscribe(_:)`, independent of Firebase configuration**

Find:
```swift
    func unsubscribe(_ subscription: Subscription) {
        Log.d(tag, "Unsubscribing from \(subscription.urlString())")
        DispatchQueue.main.async {
            if let baseUrl = subscription.baseUrl, let topic = subscription.topic, FirebaseApp.app() != nil {
                let firebaseTopicName = firebaseTopic(baseUrl: baseUrl, topic: topic)
                Messaging.messaging().unsubscribe(fromTopic: firebaseTopicName) { error in
                    if let error {
                        Log.e(tag, "Firebase unsubscribe failed for \(firebaseTopicName)", error)
                    } else {
                        Log.d(tag, "Firebase unsubscribe succeeded for \(firebaseTopicName)")
                    }
                }
            }
            store.delete(subscription: subscription)
        }
    }
```

Replace with:
```swift
    func unsubscribe(_ subscription: Subscription) {
        Log.d(tag, "Unsubscribing from \(subscription.urlString())")
        let baseUrl = subscription.baseUrl
        let topic = subscription.topic
        DispatchQueue.main.async {
            if let baseUrl, let topic, FirebaseApp.app() != nil {
                let firebaseTopicName = firebaseTopic(baseUrl: baseUrl, topic: topic)
                Messaging.messaging().unsubscribe(fromTopic: firebaseTopicName) { error in
                    if let error {
                        Log.e(tag, "Firebase unsubscribe failed for \(firebaseTopicName)", error)
                    } else {
                        Log.d(tag, "Firebase unsubscribe succeeded for \(firebaseTopicName)")
                    }
                }
            }
            if let baseUrl, let topic {
                TopicSyncCoordinator.shared.localSubscriptionWasRemoved(baseUrl: baseUrl, topic: topic)
            }
            store.delete(subscription: subscription)
        }
    }
```

(`baseUrl`/`topic` are captured before the `DispatchQueue.main.async` closure since `Subscription` is a managed object best read on the context's own thread/queue — matches how the rest of this file already treats `Subscription` properties.)

- [ ] **Step 4: Build check**

Use `BuildProject`. Expected: succeeds.

- [ ] **Step 5: Run the full test suite**

Expected: same pass count as Task 6 (no new tests here — this is glue code exercised by Task 11's manual verification).

- [ ] **Step 6: Commit**

```bash
git add ntfy/Persistence/SubscriptionManager.swift
git commit -m "Mirror subscribe/unsubscribe into TopicSyncCoordinator"
```

---

### Task 8: Wire the coordinator into `Store.saveIcon`/`saveDisplayName`

**Files:**
- Modify: `ntfy/Persistence/Store.swift`

**Interfaces:**
- Consumes: `TopicSyncCoordinator.shared.localSubscriptionDidChange(_:)` (Task 6).

- [ ] **Step 1: Read the current methods**

```bash
grep -n "func saveIcon\|func saveDisplayName" -A6 ntfy/Persistence/Store.swift
```

- [ ] **Step 2: Add the sync call to both methods**

Find:
```swift
    func saveIcon(for subscription: Subscription, icon: String?) {
        context.performAndWait {
            subscription.icon = (icon?.isEmpty ?? true) ? nil : icon
            try? context.save()
        }
    }
```

Replace with:
```swift
    func saveIcon(for subscription: Subscription, icon: String?) {
        context.performAndWait {
            subscription.icon = (icon?.isEmpty ?? true) ? nil : icon
            try? context.save()
        }
        TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)
    }
```

Find:
```swift
    func saveDisplayName(for subscription: Subscription, name: String?) {
        context.performAndWait {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            subscription.customDisplayName = trimmed.isEmpty ? nil : String(trimmed.prefix(64))
            try? context.save()
        }
    }
```

Replace with:
```swift
    func saveDisplayName(for subscription: Subscription, name: String?) {
        context.performAndWait {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            subscription.customDisplayName = trimmed.isEmpty ? nil : String(trimmed.prefix(64))
            try? context.save()
        }
        TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)
    }
```

Calling the coordinator *after* `context.performAndWait` (not inside it) matters: `TopicSyncCoordinator.shared` is `@MainActor`-isolated, and `localSubscriptionDidChange` reads `subscription.baseUrl`/`.topic`/etc. — doing that after the save completes, on the same thread, avoids any question of reading managed-object properties from inside a different context's `perform` block.

- [ ] **Step 3: Build check**

Use `BuildProject`. Expected: succeeds. If `Store.swift` reports `TopicSyncCoordinator` as `@MainActor`-isolated and unreachable from a non-isolated context, confirm `saveIcon`/`saveDisplayName` are being called from the main actor already (they are, throughout this codebase — every existing caller is a SwiftUI view action).

- [ ] **Step 4: Run the full test suite**

Expected: same pass count as Task 7.

- [ ] **Step 5: Commit**

```bash
git add ntfy/Persistence/Store.swift
git commit -m "Mirror subscription icon/display-name edits into TopicSyncCoordinator"
```

---

### Task 9: Start the coordinator at launch

**Files:**
- Modify: `ntfy/App/AppMain.swift`

**Interfaces:**
- Consumes: `TopicSyncCoordinator.shared.start()` (Task 6).

- [ ] **Step 1: Read the current file**

```bash
cat -n ntfy/App/AppMain.swift
```

- [ ] **Step 2: Call `start()` once, alongside the existing `store`/`iconManager` setup**

Find the `init()` method:
```swift
    init() {
        Log.d(tag, "Launching ntfy 🥳. Welcome!")
        Log.d(tag, "Base URL is \(Config.appBaseUrl), user agent is \(ApiService.userAgent)")
    }
```

Replace with:
```swift
    init() {
        Log.d(tag, "Launching ntfy 🥳. Welcome!")
        Log.d(tag, "Base URL is \(Config.appBaseUrl), user agent is \(ApiService.userAgent)")
        Task { @MainActor in
            TopicSyncCoordinator.shared.start()
        }
    }
```

`init()` on an `App` conformer isn't `@MainActor`-isolated by default, but `TopicSyncCoordinator` is — wrapping in `Task { @MainActor in ... }` hops onto the main actor to call `start()`. This mirrors how `AppIconManager()` and `Store.shared` are otherwise only ever touched from SwiftUI's main-actor context in this file.

- [ ] **Step 3: Build check**

Use `BuildProject`. Expected: succeeds.

- [ ] **Step 4: Run the full test suite**

Expected: same pass count as Task 8.

- [ ] **Step 5: Commit**

```bash
git add ntfy/App/AppMain.swift
git commit -m "Start TopicSyncCoordinator at launch"
```

---

### Task 10: Settings status row

**Files:**
- Create: `ntfy/Views/Settings/iCloudSyncSettingView.swift`
- Modify: `ntfy/Views/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `FileManager.default.ubiquityIdentityToken` (system API — `nil` means not signed into iCloud). Does not need anything from `TopicSyncStore` directly — sync itself is automatic and has no per-topic UI here, only a status readout.

This follows the same row pattern as `FirebaseConfigView.swift` (Button row showing a status string).

- [ ] **Step 1: Read `FirebaseConfigView.swift` for the exact pattern to mirror**

```bash
cat -n ntfy/Views/Settings/FirebaseConfigView.swift
```

- [ ] **Step 2: Create `iCloudSyncSettingView.swift`**

```swift
// ntfy/Views/Settings/iCloudSyncSettingView.swift
import SwiftUI

/// Shows whether topic sync via iCloud is active. There's nothing to configure here — sync is
/// automatic once the user is signed into iCloud — so this is a read-only status row, unlike
/// FirebaseConfigView's import/remove flow.
struct iCloudSyncSettingView: View {
    @State private var isSignedIntoiCloud = FileManager.default.ubiquityIdentityToken != nil

    private var statusText: String {
        isSignedIntoiCloud ? "Synced" : "Not signed into iCloud"
    }

    var body: some View {
        HStack {
            Text("Topic Sync")
                .foregroundStyle(.primary)
            Spacer()
            Text(statusText)
                .foregroundStyle(.gray)
        }
        .onAppear {
            isSignedIntoiCloud = FileManager.default.ubiquityIdentityToken != nil
        }
    }
}

#Preview {
    Form {
        iCloudSyncSettingView()
    }
}
```

(Swift type names conventionally start uppercase — `iCloudSyncSettingView` deliberately starts lowercase to match "iCloud"'s own capitalization, the same way Apple's own APIs like `iCloudDriveView`-style naming would; if this trips up lint tooling in this project, rename to `ICloudSyncSettingView` instead and adjust the references in Step 3 accordingly.)

- [ ] **Step 3: Wire it into `SettingsView.swift`**

```bash
grep -n "Section" -A3 ntfy/Views/Settings/SettingsView.swift | head -30
```

Add a new `Section` — following the existing pattern of one `Section` per settings row-view — near the `DefaultServerView`/`FirebaseConfigView` sections (both about connectivity):

```swift
Section(
    header: Text("iCloud"),
    footer: Text("Your subscribed topics sync automatically across your devices when you're signed into iCloud.")
) {
    iCloudSyncSettingView()
}
```

- [ ] **Step 4: Build check**

Use `BuildProject`. Expected: succeeds.

- [ ] **Step 5: Render the preview**

Use `RenderPreview` on `iCloudSyncSettingView.swift` and on `SettingsView.swift`. Expected: the new row renders without crashing (it will show "Not signed into iCloud" in Simulator/Preview unless the preview environment happens to have an iCloud account).

- [ ] **Step 6: Run the full test suite**

Expected: same pass count as Task 9.

- [ ] **Step 7: Commit**

```bash
git add ntfy/Views/Settings/iCloudSyncSettingView.swift ntfy/Views/Settings/SettingsView.swift
git commit -m "Add iCloud topic sync status row to Settings"
```

---

### Task 11: Account-change handling

**Files:**
- Modify: `ntfy/Persistence/TopicSyncStore.swift`
- Modify: `ntfy/Persistence/TopicSyncCoordinator.swift`

**Interfaces:**
- Produces: `TopicSyncStore` posts `NSNotification.Name("TopicSyncStore.accountChanged")` when it detects a CloudKit account change. `TopicSyncCoordinator` observes it and re-runs bootstrap reconciliation.

- [ ] **Step 1: Add account-change observation to `TopicSyncStore`**

In `TopicSyncStore.swift`, add a new notification name and observe `NSPersistentCloudKitContainer.eventChangedNotification`, filtering for account-change events:

```swift
    static let accountChangedNotification = NSNotification.Name("TopicSyncStore.accountChanged")
```

In `init(inMemory:)`, after the existing `.NSPersistentStoreRemoteChange` subscription (inside the same `guard !inMemory else { return }` block, so this is skipped for the in-memory test path too):

```swift
        NotificationCenter.default
            .publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .compactMap { $0.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event }
            .filter { $0.type == .setup && $0.succeeded == false }
            .sink { [weak self] _ in
                guard let self else { return }
                Log.w(TopicSyncStore.tag, "CloudKit account setup failed or changed; clearing local replica")
                self.clearLocalReplica()
                NotificationCenter.default.post(name: TopicSyncStore.accountChangedNotification, object: self)
            }
            .store(in: &cancellables)
```

Add the `clearLocalReplica()` helper (deletes every local `SyncedTopic` — the CloudKit mirror will repopulate from whichever account is now active):

```swift
    private func clearLocalReplica() {
        context.performAndWait {
            for syncedTopic in allSyncedTopics() {
                context.delete(syncedTopic)
            }
            try? context.save()
        }
    }
```

- [ ] **Step 2: React to it in `TopicSyncCoordinator`**

In `TopicSyncCoordinator.start()`, add a second subscription alongside the existing one:

```swift
    func start() {
        reconcileFromRemote(initialBootstrap: true)
        NotificationCenter.default
            .publisher(for: TopicSyncStore.didChangeNotification)
            .sink { [weak self] _ in self?.reconcileFromRemote(initialBootstrap: false) }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: TopicSyncStore.accountChangedNotification)
            .sink { [weak self] _ in self?.reconcileFromRemote(initialBootstrap: true) }
            .store(in: &cancellables)
    }
```

Re-running with `initialBootstrap: true` after an account change re-uploads every local subscription to the (now different) account instead of treating them all as "unsubscribed elsewhere" — matching the spec's requirement that a shared/borrowed device doesn't mix two accounts' topic lists.

- [ ] **Step 3: Build check**

Use `BuildProject`. Expected: succeeds. If `NSPersistentCloudKitContainer.Event`'s exact property names (`type`, `succeeded`) don't match this SDK version, check `NSPersistentCloudKitContainer.EventType` and `NSPersistentCloudKitContainer.Event` in Xcode's quick help / the `DocumentationSearch` tool and adjust the `.filter` accordingly — the intent is "the setup event failed or a different account is now in use," not the exact API shape.

- [ ] **Step 4: Run the full test suite**

Expected: same pass count as Task 10 (Task 5's in-memory tests still pass unaffected, since this code path is skipped for `inMemory: true`).

- [ ] **Step 5: Commit**

```bash
git add ntfy/Persistence/TopicSyncStore.swift ntfy/Persistence/TopicSyncCoordinator.swift
git commit -m "Handle iCloud account changes by re-bootstrapping topic sync"
```

---

### Task 12: Manual on-device verification

CloudKit sync cannot be exercised in this development environment (no real iCloud account/network path here) — this task is a checklist for the user, run after all prior tasks are merged and the app is installed on real devices signed into the same iCloud account.

- [ ] **Step 1:** Install the app on two devices (or a device + simulator, though CloudKit sync typically needs real devices) signed into the same iCloud account.
- [ ] **Step 2:** Subscribe to a new topic on Device A. Confirm it appears in Device B's subscription list within roughly a minute (CloudKit push propagation isn't instant).
- [ ] **Step 3:** Unsubscribe from that topic on Device B. Confirm it disappears from Device A.
- [ ] **Step 4:** Rename a topic (custom display name) on Device A. Confirm the new name appears on Device B.
- [ ] **Step 5:** Change a topic's icon on Device A. Confirm it updates on Device B.
- [ ] **Step 6:** On a fresh install with existing local subscriptions (simulating "had the app before this feature shipped"), confirm those subscriptions get uploaded to iCloud rather than treated as remote deletions (this exercises the `initialBootstrap` path in `TopicSyncCoordinator.reconcileFromRemote`).
- [ ] **Step 7:** Turn off iCloud Drive (Settings → [Your Name] → iCloud) on one device. Confirm the app continues to work normally for local subscribe/unsubscribe, and the Settings → iCloud row shows "Not signed into iCloud".
- [ ] **Step 8:** Turn iCloud back on. Confirm the device catches back up with whatever changed while it was off.

No commit for this task — it's verification only. If any step fails, file it as a follow-up rather than trying to fix it blind; CloudKit sync bugs are usually timing/state issues that need to be reproduced with real device logs.
