# iOS 27 Feature Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adopt four iOS 27 features in the ntfy iOS app: an `alert(item:)` refactor in two views, toolbar minimize-on-scroll, iCloud-synced drag-to-reorder for subscribed topics, and a first App Intent for publishing a message via Shortcuts/Siri.

**Architecture:** Bump the deployment target first since every later task uses iOS-27-only APIs unconditionally (no `@available` gating anywhere). The two small SwiftUI refactors (alert, toolbar) are self-contained UI changes. The reorder feature threads a new `sortRank` field through the existing local Core Data store (`Store`), the existing CloudKit-mirrored store (`TopicSyncStore`), and the existing reconciliation logic (`TopicSyncCoordinator`/`TopicSyncDiff`) — following the exact pattern already used for `customDisplayName`/`icon`. The App Intent is new, isolated code added in its own `AppIntents/` group with no changes to existing files besides none (it only reads from `Store`/`ApiService`, which already expose everything it needs).

**Tech Stack:** Swift, SwiftUI (iOS 27 SDK), Core Data (+ `NSPersistentCloudKitContainer`), XCTest, AppIntents framework.

## Global Constraints

- Deployment target for every target (`ntfy`, `ntfyNSE`, test targets) is iOS 27.0 as of Task 1. No `@available`/`if #available` gating in any task below — every new API is used unconditionally.
- Follow the existing `syncToCloud: Bool = true` convention exactly wherever a new `Store` method mirrors a Core Data write out to `TopicSyncCoordinator` (see `saveIcon`/`saveDisplayName` in `ntfy/Persistence/Store.swift`).
- Build with the `BuildProject` MCP tool (or Xcode's Build) after every task that touches compiled Swift/Core Data model files. Run affected XCTest targets with the `RunSomeTests` MCP tool (or Xcode's Test action); the underlying command is `xcodebuild test -scheme ntfy -only-testing:ntfyTests/<TestClass>` if invoking directly.
- Commit after every task, not just at the end.

---

### Task 1: Bump deployment target to iOS 27

**Files:**
- Modify: `ntfy.xcodeproj/project.pbxproj` (8 occurrences of `IPHONEOS_DEPLOYMENT_TARGET = 26.0;`)

**Interfaces:**
- Consumes: nothing.
- Produces: every target now compiles against iOS 27 SDK APIs unconditionally. All later tasks depend on this.

- [ ] **Step 1: Replace every occurrence**

```bash
sed -i '' 's/IPHONEOS_DEPLOYMENT_TARGET = 26.0;/IPHONEOS_DEPLOYMENT_TARGET = 27.0;/g' /Users/hibikipr/Developer/ntfy-ios/ntfy.xcodeproj/project.pbxproj
```

- [ ] **Step 2: Verify the replacement**

```bash
grep -c "IPHONEOS_DEPLOYMENT_TARGET = 27.0;" /Users/hibikipr/Developer/ntfy-ios/ntfy.xcodeproj/project.pbxproj
grep -c "IPHONEOS_DEPLOYMENT_TARGET = 26.0;" /Users/hibikipr/Developer/ntfy-ios/ntfy.xcodeproj/project.pbxproj
```
Expected: first command prints `8`, second prints `0`.

- [ ] **Step 3: Build the project**

Use the `BuildProject` MCP tool.
Expected: build succeeds (nothing in the codebase uses an iOS-27-only API yet, so this is purely a floor-raise).

- [ ] **Step 4: Commit**

```bash
git add ntfy.xcodeproj/project.pbxproj
git commit -m "Bump deployment target to iOS 27"
```

---

### Task 2: alert(item:) refactor — NotificationListView

**Files:**
- Modify: `ntfy/Views/Notifications/NotificationListView.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing consumed by later tasks — this is a self-contained refactor.

- [ ] **Step 1: Replace the `ActiveAlert` enum and the two `@State` properties**

Replace:
```swift
enum ActiveAlert {
    case clear, unsubscribe, selected
}
```
and
```swift
    @State private var showAlert = false
    @State private var activeAlert: ActiveAlert = .clear
```
with:
```swift
private enum PendingAlert: Identifiable {
    case clear, unsubscribe, selected
    var id: Self { self }

    var title: String {
        switch self {
        case .clear: return "Clear notifications"
        case .unsubscribe: return "Unsubscribe"
        case .selected: return "Delete"
        }
    }
}
```
and
```swift
    @State private var pendingAlert: PendingAlert?
```
(`PendingAlert` replaces the top-level `enum ActiveAlert` — remove that top-level declaration entirely; the new enum is nested as a private type inside the file, above `NotificationListView`.)

- [ ] **Step 2: Update the three call sites that set the old state**

Replace:
```swift
                        Button("Clear all notifications") {
                                self.showAlert = true
                                self.activeAlert = .clear
                            }
```
with:
```swift
                        Button("Clear all notifications") {
                                self.pendingAlert = .clear
                            }
```

Replace:
```swift
                        Button("Unsubscribe") {
                        self.showAlert = true
                        self.activeAlert = .unsubscribe
                    }
```
with:
```swift
                        Button("Unsubscribe") {
                        self.pendingAlert = .unsubscribe
                    }
```

Replace:
```swift
                    Button(action: {
                        self.showAlert = true
                        self.activeAlert = .selected
                    }) {
```
with:
```swift
                    Button(action: {
                        self.pendingAlert = .selected
                    }) {
```

- [ ] **Step 3: Replace the alert modifier**

Replace the entire:
```swift
        .alert(isPresented: $showAlert) {
            switch activeAlert {
            case .clear:
                return Alert(
                    title: Text("Clear notifications"),
                    message: Text("Do you really want to delete all of the notifications in this topic?"),
                    primaryButton: .destructive(
                        Text("Permanently delete"),
                        action: deleteAll
                    ),
                    secondaryButton: .cancel())
            case .unsubscribe:
                return Alert(
                    title: Text("Unsubscribe"),
                    message: Text("Do you really want to unsubscribe from this topic and delete all of the notifications you received?"),
                    primaryButton: .destructive(
                        Text("Unsubscribe"),
                        action: unsubscribe
                    ),
                    secondaryButton: .cancel())
            case .selected:
                return Alert(
                    title: Text("Delete"),
                    message: Text("Do you really want to delete these selected notifications?"),
                    primaryButton: .destructive(
                        Text("Delete"),
                        action: deleteSelected
                    ),
                    secondaryButton: .cancel())
            }
        }
```
with:
```swift
        .alert(Text(pendingAlert?.title ?? ""), item: $pendingAlert) { alert in
            switch alert {
            case .clear:
                Button("Permanently delete", role: .destructive, action: deleteAll)
                Button("Cancel", role: .cancel) {}
            case .unsubscribe:
                Button("Unsubscribe", role: .destructive, action: unsubscribe)
                Button("Cancel", role: .cancel) {}
            case .selected:
                Button("Delete", role: .destructive, action: deleteSelected)
                Button("Cancel", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case .clear:
                Text("Do you really want to delete all of the notifications in this topic?")
            case .unsubscribe:
                Text("Do you really want to unsubscribe from this topic and delete all of the notifications you received?")
            case .selected:
                Text("Do you really want to delete these selected notifications?")
            }
        }
```

- [ ] **Step 4: Build**

Use the `BuildProject` MCP tool.
Expected: build succeeds. If `alert(_:item:actions:message:)` reports an overload-resolution error, use `DocumentationSearch` for `alert(_:item:actions:message:)` to confirm the exact title-parameter type (`Text` vs `LocalizedStringKey` vs a generic `S: StringProtocol`) and adjust the `Text(pendingAlert?.title ?? "")` expression's wrapper type accordingly — the surrounding logic (the `PendingAlert` enum, the `item:` binding, the two closures) does not change.

- [ ] **Step 5: Manually verify in a simulator (or the `run` skill) that all three alerts (clear all, unsubscribe, delete selected) still show the correct title, message, and buttons, and that each button still performs its original action.**

- [ ] **Step 6: Commit**

```bash
git add ntfy/Views/Notifications/NotificationListView.swift
git commit -m "Refactor NotificationListView alerts to alert(item:)"
```

---

### Task 3: alert(item:) refactor — SubscriptionListView

**Files:**
- Modify: `ntfy/Views/Subscriptions/SubscriptionListView.swift` (the `SubscriptionItemNavView` struct)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Replace the `@State` property**

Replace:
```swift
    @State private var unsubscribeAlert = false
```
with:
```swift
    @State private var pendingUnsubscribe: Subscription?
```

- [ ] **Step 2: Update the swipe action**

Replace:
```swift
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                self.unsubscribeAlert = true
            } label: {
                Label("Delete", systemImage: "trash.circle")
            }
        }
```
with:
```swift
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                self.pendingUnsubscribe = subscription
            } label: {
                Label("Delete", systemImage: "trash.circle")
            }
        }
```

- [ ] **Step 3: Replace the alert modifier**

Replace:
```swift
        .alert(isPresented: $unsubscribeAlert) {
            Alert(
                title: Text("Unsubscribe"),
                message: Text("Do you really want to unsubscribe from this topic and delete all of the notifications you received?"),
                primaryButton: .destructive(
                    Text("Unsubscribe"),
                    action: {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        self.subscriptionManager.unsubscribe(subscription)
                        self.unsubscribeAlert = false
                    }
                ),
                secondaryButton: .cancel()
            )
        }
```
with:
```swift
        .alert("Unsubscribe", item: $pendingUnsubscribe) { subscriptionToUnsubscribe in
            Button("Unsubscribe", role: .destructive) {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                self.subscriptionManager.unsubscribe(subscriptionToUnsubscribe)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Do you really want to unsubscribe from this topic and delete all of the notifications you received?")
        }
```

- [ ] **Step 4: Build**

Use the `BuildProject` MCP tool. Expected: build succeeds.

- [ ] **Step 5: Manually verify the swipe-to-delete unsubscribe confirmation still works in a simulator.**

- [ ] **Step 6: Commit**

```bash
git add ntfy/Views/Subscriptions/SubscriptionListView.swift
git commit -m "Refactor SubscriptionListView unsubscribe alert to alert(item:)"
```

---

### Task 4: Toolbar minimize behavior — NotificationListView

**Files:**
- Modify: `ntfy/Views/Notifications/NotificationListView.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the modifier**

In `notificationList`, immediately after the existing `.listStyle(.insetGrouped)` line, add:
```swift
        .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
```

- [ ] **Step 2: Build**

Use the `BuildProject` MCP tool. Expected: build succeeds.

- [ ] **Step 3: Manually verify in a simulator that scrolling down in a topic with many messages minimizes the navigation bar, and scrolling up restores it.**

- [ ] **Step 4: Commit**

```bash
git add ntfy/Views/Notifications/NotificationListView.swift
git commit -m "Minimize NotificationListView's toolbar on scroll"
```

---

### Task 5: Core Data model changes — add sortRank

**Files:**
- Modify: `ntfy/Persistence/ntfy.xcdatamodeld/Model.xcdatamodel/contents`
- Modify: `ntfy/Persistence/TopicSync.xcdatamodeld/TopicSync.xcdatamodel/contents`

**Interfaces:**
- Consumes: nothing.
- Produces: `Subscription.sortRank: Double` (non-optional, default `0`) and `SyncedTopic.sortRank: NSNumber?` (optional numeric — Core Data's codegen for an optional `Double` attribute with `usesScalarValueType="NO"` is `NSNumber?`, not `Double?`; every later task that reads/writes `SyncedTopic.sortRank` must convert with `.doubleValue` / `NSNumber(value:)`).

- [ ] **Step 1: Add `sortRank` to the `Subscription` entity**

In `ntfy/Persistence/ntfy.xcdatamodeld/Model.xcdatamodel/contents`, inside the `<entity name="Subscription" ...>` element, add (alongside the other attributes, e.g. right after `lastNotificationId`):
```xml
        <attribute name="sortRank" attributeType="Double" defaultValueString="0" usesScalarValueType="YES"/>
```
This is non-optional with a default, exactly like `Notification.time` in the same model file — it qualifies for automatic lightweight migration (both persistent store descriptions already set `shouldMigrateStoreAutomatically`/`shouldInferMappingModelAutomatically` in `Store.init`).

- [ ] **Step 2: Add `sortRank` to the `SyncedTopic` entity**

In `ntfy/Persistence/TopicSync.xcdatamodeld/TopicSync.xcdatamodel/contents`, inside the `<entity name="SyncedTopic" ...>` element, add (alongside the other attributes, e.g. right after `icon`):
```xml
        <attribute name="sortRank" optional="YES" attributeType="Double" usesScalarValueType="NO"/>
```
Must be `optional="YES"` and non-scalar (`usesScalarValueType="NO"`) — the model file's own top-of-file comment documents that every attribute in this CloudKit-mirrored entity must be optional or defaulted, and a true optional numeric needs to be boxed (`NSNumber?`), since a C scalar cannot represent "not set".

- [ ] **Step 3: Build**

Use the `BuildProject` MCP tool. Expected: build succeeds, and Xcode's Core Data codegen produces `@NSManaged public var sortRank: Double` on `Subscription` and `@NSManaged public var sortRank: NSNumber?` on `SyncedTopic`.

- [ ] **Step 4: Commit**

```bash
git add ntfy/Persistence/ntfy.xcdatamodeld/Model.xcdatamodel/contents ntfy/Persistence/TopicSync.xcdatamodeld/TopicSync.xcdatamodel/contents
git commit -m "Add sortRank attribute to Subscription and SyncedTopic"
```

---

### Task 6: Rank-midpoint helper (TDD)

**Files:**
- Create: `ntfy/Persistence/TopicRank.swift`
- Create: `ntfyTests/TopicRankTests.swift`

**Interfaces:**
- Consumes: nothing (pure function, no Core Data dependency — same style as `TopicSyncDiff`).
- Produces: `TopicRank.rank(insertingBefore: Int, in: [Double]) -> Double`, used by Task 11's reorder UI wiring.

- [ ] **Step 1: Write the failing tests**

Create `ntfyTests/TopicRankTests.swift`:
```swift
import XCTest
@testable import ntfy

final class TopicRankTests: XCTestCase {
    func testInsertingIntoEmptyListReturnsZero() {
        XCTAssertEqual(TopicRank.rank(insertingBefore: 0, in: []), 0)
    }

    func testInsertingAtFrontIsLessThanCurrentFirst() {
        let rank = TopicRank.rank(insertingBefore: 0, in: [5, 10, 15])
        XCTAssertEqual(rank, 4)
    }

    func testInsertingAtEndIsGreaterThanCurrentLast() {
        let rank = TopicRank.rank(insertingBefore: 3, in: [5, 10, 15])
        XCTAssertEqual(rank, 16)
    }

    func testInsertingInTheMiddleIsTheMidpointOfItsNeighbors() {
        let rank = TopicRank.rank(insertingBefore: 1, in: [5, 10, 15])
        XCTAssertEqual(rank, 7.5)
    }

    func testDestinationIndexBeyondBoundsClampsToEnd() {
        let rank = TopicRank.rank(insertingBefore: 99, in: [5, 10, 15])
        XCTAssertEqual(rank, 16)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile (TopicRank doesn't exist yet)**

Use the `RunSomeTests` MCP tool for `ntfyTests/TopicRankTests`.
Expected: FAIL — "cannot find 'TopicRank' in scope".

- [ ] **Step 3: Write the implementation**

Create `ntfy/Persistence/TopicRank.swift`:
```swift
import Foundation

/// Pure helper for computing a moved topic's new `Subscription.sortRank` from a drag-to-reorder,
/// without rewriting every other row's rank. Keeping a reorder to a single changed field is what
/// lets it use the same last-write-wins sync semantics as `customDisplayName`/`icon` — see
/// docs/superpowers/specs/2026-09-11-ios27-adoption-design.md.
enum TopicRank {
    /// - Parameters:
    ///   - destinationIndex: the index within `orderedRanks` the moved topic should land before
    ///     (`orderedRanks.count` or beyond means "move to the end").
    ///   - orderedRanks: the current ranks of every *other* topic, in their current display
    ///     order (i.e. with the moved topic already removed).
    static func rank(insertingBefore destinationIndex: Int, in orderedRanks: [Double]) -> Double {
        if orderedRanks.isEmpty {
            return 0
        }
        if destinationIndex <= 0 {
            return orderedRanks[0] - 1
        }
        if destinationIndex >= orderedRanks.count {
            return orderedRanks[orderedRanks.count - 1] + 1
        }
        return (orderedRanks[destinationIndex - 1] + orderedRanks[destinationIndex]) / 2
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Use the `RunSomeTests` MCP tool for `ntfyTests/TopicRankTests`.
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add ntfy/Persistence/TopicRank.swift ntfyTests/TopicRankTests.swift
git commit -m "Add TopicRank fractional-rank helper for topic reordering"
```

---

### Task 7: Store — saveSortRank, initial rank on subscribe, one-time backfill

**Files:**
- Modify: `ntfy/Persistence/Store.swift`

**Interfaces:**
- Consumes: `Subscription.sortRank: Double` (Task 5).
- Produces: `Store.saveSortRank(for subscription: Subscription, rank: Double, syncToCloud: Bool = true)`, used by Task 10 (`TopicSyncCoordinator`) and Task 11 (`SubscriptionListView`).

- [ ] **Step 1: Add `saveSortRank`, mirroring `saveIcon`/`saveDisplayName`**

Immediately after the existing `saveDisplayName` method in `ntfy/Persistence/Store.swift`, add:
```swift
    /// - Parameter syncToCloud: see `saveIcon(for:icon:syncToCloud:)`.
    func saveSortRank(for subscription: Subscription, rank: Double, syncToCloud: Bool = true) {
        context.performAndWait {
            subscription.sortRank = rank
            try? context.save()
        }
        #if !NTFY_NSE
        if syncToCloud {
            Task { @MainActor in
                TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)
            }
        }
        #endif
    }
```

- [ ] **Step 2: Assign an initial rank in `saveSubscription`**

Replace:
```swift
    func saveSubscription(baseUrl: String, topic: String) -> Subscription {
        // `context.performAndWait`, not `DispatchQueue.main.sync`: this is called both from a
        // background queue (SubscriptionAddView) and, since TopicSyncCoordinator's reconciliation
        // now genuinely runs on the main actor, from the main thread — where `main.sync` would
        // deadlock instantly. `performAndWait` is reentrant on the context's own queue, and also
        // puts the object's creation on that queue instead of on the caller's thread.
        var subscription: Subscription!
        context.performAndWait {
            subscription = Subscription(context: context)
            subscription.baseUrl = normalizeBaseUrl(baseUrl)
            subscription.topic = topic
            Log.d(Store.tag, "Storing subscription baseUrl=\(subscription.baseUrl ?? "?"), topic=\(topic)")
            try? context.save()
        }
        return subscription
    }
```
with:
```swift
    func saveSubscription(baseUrl: String, topic: String) -> Subscription {
        // `context.performAndWait`, not `DispatchQueue.main.sync`: this is called both from a
        // background queue (SubscriptionAddView) and, since TopicSyncCoordinator's reconciliation
        // now genuinely runs on the main actor, from the main thread — where `main.sync` would
        // deadlock instantly. `performAndWait` is reentrant on the context's own queue, and also
        // puts the object's creation on that queue instead of on the caller's thread.
        var subscription: Subscription!
        context.performAndWait {
            // New topics land at the end of the manually-ordered list.
            let maxRank = ((try? context.fetch(Subscription.fetchRequest())) ?? []).map(\.sortRank).max() ?? -1
            subscription = Subscription(context: context)
            subscription.baseUrl = normalizeBaseUrl(baseUrl)
            subscription.topic = topic
            subscription.sortRank = maxRank + 1
            Log.d(Store.tag, "Storing subscription baseUrl=\(subscription.baseUrl ?? "?"), topic=\(topic)")
            try? context.save()
        }
        return subscription
    }
```

- [ ] **Step 3: Add the one-time backfill for existing installs**

Add this new private method anywhere in `Store` (e.g. right after `hardRefresh()`):
```swift
    /// Existing installs upgrading to this version have every `Subscription.sortRank` at its
    /// migration default of `0`. Backfill each one to its position in the *current* display
    /// order (alphabetical by topic, matching what `SubscriptionsObservable` sorted by before
    /// this feature existed) exactly once, so nobody's topic list visibly reshuffles the moment
    /// they update. Gated by a UserDefaults flag so it never runs a second time.
    private func backfillSortRankIfNeeded() {
        let defaultsKey = "Store.didBackfillSortRank"
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        context.performAndWait {
            let request = Subscription.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "topic", ascending: true)]
            let subscriptions = (try? context.fetch(request)) ?? []
            for (index, subscription) in subscriptions.enumerated() {
                subscription.sortRank = Double(index)
            }
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: defaultsKey)
    }
```

Then call it in `init`, right before the existing `unreadCount = unreadNotificationCount()` line:
```swift
        backfillSortRankIfNeeded()
        unreadCount = unreadNotificationCount()
```

- [ ] **Step 4: Build**

Use the `BuildProject` MCP tool. Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add ntfy/Persistence/Store.swift
git commit -m "Add Store.saveSortRank, assign initial rank on subscribe, backfill existing installs"
```

---

### Task 8: TopicSyncDiff — sortRank in the metadata diff (TDD)

**Files:**
- Modify: `ntfy/Persistence/TopicSyncDiff.swift`
- Modify: `ntfyTests/TopicSyncDiffTests.swift`

**Interfaces:**
- Consumes: nothing new (this task only touches the plain `TopicMetadata` struct, not Core Data).
- Produces: `TopicMetadata.sortRank: Double?` and `TopicSyncDiff.metadataChanged` now also flags a `sortRank`-only difference. Consumed by Task 10 (`TopicSyncCoordinator`).

- [ ] **Step 1: Write the failing tests**

Add to `ntfyTests/TopicSyncDiffTests.swift`, inside the `// MARK: - metadataChanged` section:
```swift
    func testMetadataChangedDetectsSortRankChange() {
        let identity = TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")
        let local = [TopicMetadata(identity: identity, customDisplayName: nil, icon: nil, sortRank: 0)]
        let synced = [TopicMetadata(identity: identity, customDisplayName: nil, icon: nil, sortRank: 1)]
        XCTAssertEqual(TopicSyncDiff.metadataChanged(local: local, synced: synced), [identity])
    }

    func testMetadataChangedIgnoresIdenticalSortRank() {
        let identity = TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")
        let local = [TopicMetadata(identity: identity, customDisplayName: "Same", icon: "bell", sortRank: 2)]
        let synced = [TopicMetadata(identity: identity, customDisplayName: "Same", icon: "bell", sortRank: 2)]
        XCTAssertTrue(TopicSyncDiff.metadataChanged(local: local, synced: synced).isEmpty)
    }

    func testMetadataChangedTreatsNilAndSetSortRankAsDifferent() {
        let identity = TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")
        let local = [TopicMetadata(identity: identity, customDisplayName: nil, icon: nil, sortRank: nil)]
        let synced = [TopicMetadata(identity: identity, customDisplayName: nil, icon: nil, sortRank: 3)]
        XCTAssertEqual(TopicSyncDiff.metadataChanged(local: local, synced: synced), [identity])
    }
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Use the `RunSomeTests` MCP tool for `ntfyTests/TopicSyncDiffTests`.
Expected: FAIL — "extra argument 'sortRank' in call" (the struct doesn't have that member yet).

- [ ] **Step 3: Add `sortRank` to `TopicMetadata` and extend `metadataChanged`**

Replace:
```swift
struct TopicMetadata: Hashable {
    let identity: TopicIdentity
    let customDisplayName: String?
    let icon: String?
}
```
with:
```swift
struct TopicMetadata: Hashable {
    let identity: TopicIdentity
    let customDisplayName: String?
    let icon: String?
    let sortRank: Double? = nil
}
```
(Giving `sortRank` a default of `nil` on the property itself means the synthesized memberwise initializer also defaults it to `nil` — every existing call site in `TopicSyncDiffTests.swift` that doesn't mention `sortRank` keeps compiling unchanged.)

Replace:
```swift
    static func metadataChanged(local: [TopicMetadata], synced: [TopicMetadata]) -> [TopicIdentity] {
        let localByIdentity = Dictionary(uniqueKeysWithValues: local.map { ($0.identity, $0) })
        return synced.compactMap { remote in
            guard let localEntry = localByIdentity[remote.identity] else { return nil }
            let changed = localEntry.customDisplayName != remote.customDisplayName
                || localEntry.icon != remote.icon
            return changed ? remote.identity : nil
        }
    }
```
with:
```swift
    static func metadataChanged(local: [TopicMetadata], synced: [TopicMetadata]) -> [TopicIdentity] {
        let localByIdentity = Dictionary(uniqueKeysWithValues: local.map { ($0.identity, $0) })
        return synced.compactMap { remote in
            guard let localEntry = localByIdentity[remote.identity] else { return nil }
            let changed = localEntry.customDisplayName != remote.customDisplayName
                || localEntry.icon != remote.icon
                || localEntry.sortRank != remote.sortRank
            return changed ? remote.identity : nil
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Use the `RunSomeTests` MCP tool for `ntfyTests/TopicSyncDiffTests`.
Expected: PASS (all existing tests plus the 3 new ones — 11 total).

- [ ] **Step 5: Commit**

```bash
git add ntfy/Persistence/TopicSyncDiff.swift ntfyTests/TopicSyncDiffTests.swift
git commit -m "Detect sortRank changes in TopicSyncDiff.metadataChanged"
```

---

### Task 9: TopicSyncStore — sortRank in upsert (TDD)

**Files:**
- Modify: `ntfy/Persistence/TopicSyncStore.swift`
- Modify: `ntfyTests/TopicSyncStoreTests.swift`

**Interfaces:**
- Consumes: `SyncedTopic.sortRank: NSNumber?` (Task 5).
- Produces: `TopicSyncStore.upsert(baseUrl:topic:customDisplayName:icon:sortRank:)` (new `sortRank: Double? = nil` parameter, boxed to `NSNumber?` before assignment). Consumed by Task 10.

- [ ] **Step 1: Write the failing tests**

Add to `ntfyTests/TopicSyncStoreTests.swift`, near `testUpsertThenFetchReturnsTheSameTopic`:
```swift
    func testUpsertThenFetchRoundTripsSortRank() {
        let store = TopicSyncStore(inMemory: true)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "alerts", customDisplayName: "Alerts", icon: "🔔", sortRank: 2.5)

        let topics = store.allSyncedTopics()
        XCTAssertEqual(topics.first?.sortRank?.doubleValue, 2.5)
    }

    func testUpsertWithoutSortRankLeavesItNil() {
        let store = TopicSyncStore(inMemory: true)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "alerts", customDisplayName: "Alerts", icon: "🔔")

        let topics = store.allSyncedTopics()
        XCTAssertNil(topics.first?.sortRank)
    }
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Use the `RunSomeTests` MCP tool for `ntfyTests/TopicSyncStoreTests`.
Expected: FAIL — "extra argument 'sortRank' in call".

- [ ] **Step 3: Add the `sortRank` parameter to `upsert`**

Replace:
```swift
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
```
with:
```swift
    func upsert(baseUrl: String, topic: String, customDisplayName: String?, icon: String?, sortRank: Double? = nil) {
        context.performAndWait {
            let recordName = "\(baseUrl)|\(topic)"
            let syncedTopic = (try? fetchByRecordName(recordName)) ?? SyncedTopic(context: context)
            syncedTopic.recordName = recordName
            syncedTopic.baseUrl = baseUrl
            syncedTopic.topic = topic
            syncedTopic.customDisplayName = customDisplayName
            syncedTopic.icon = icon
            syncedTopic.sortRank = sortRank.map { NSNumber(value: $0) }
            syncedTopic.lastModified = Date()
            try? context.save()
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Use the `RunSomeTests` MCP tool for `ntfyTests/TopicSyncStoreTests`.
Expected: PASS (all existing tests plus the 2 new ones).

- [ ] **Step 5: Commit**

```bash
git add ntfy/Persistence/TopicSyncStore.swift ntfyTests/TopicSyncStoreTests.swift
git commit -m "Add sortRank parameter to TopicSyncStore.upsert"
```

---

### Task 10: TopicSyncCoordinator — thread sortRank through reconciliation

**Files:**
- Modify: `ntfy/Persistence/TopicSyncCoordinator.swift`

**Interfaces:**
- Consumes: `Store.saveSortRank` (Task 7), `TopicMetadata.sortRank` (Task 8), `TopicSyncStore.upsert(...sortRank:)` (Task 9).
- Produces: full round-trip sync of `sortRank`, matching how `customDisplayName`/`icon` already round-trip.

- [ ] **Step 1: Pass `sortRank` in `localSubscriptionDidChange`**

Replace:
```swift
    func localSubscriptionDidChange(_ subscription: Subscription) {
        guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return }
        TopicSyncStore.shared.upsert(
            baseUrl: baseUrl,
            topic: topic,
            customDisplayName: subscription.customDisplayName,
            icon: subscription.icon
        )
    }
```
with:
```swift
    func localSubscriptionDidChange(_ subscription: Subscription) {
        guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return }
        TopicSyncStore.shared.upsert(
            baseUrl: baseUrl,
            topic: topic,
            customDisplayName: subscription.customDisplayName,
            icon: subscription.icon,
            sortRank: subscription.sortRank
        )
    }
```

- [ ] **Step 2: Pass `sortRank` in the initial-bootstrap upload block**

Replace:
```swift
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
```
with:
```swift
        if mode == .initialBootstrap {
            for identity in localOnly {
                guard let subscription = local.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic }) else { continue }
                TopicSyncStore.shared.upsert(
                    baseUrl: identity.baseUrl,
                    topic: identity.topic,
                    customDisplayName: subscription.customDisplayName,
                    icon: subscription.icon,
                    sortRank: subscription.sortRank
                )
            }
            hasBootstrappedCurrentAccount = true
        }
```

- [ ] **Step 3: Include `sortRank` when building `TopicMetadata` for the diff**

Replace:
```swift
        let syncedMetadata = synced.compactMap { syncedTopic -> TopicMetadata? in
            guard let baseUrl = syncedTopic.baseUrl, let topic = syncedTopic.topic else { return nil }
            return TopicMetadata(
                identity: TopicIdentity(baseUrl: baseUrl, topic: topic),
                customDisplayName: syncedTopic.customDisplayName,
                icon: syncedTopic.icon
            )
        }
        let localMetadata = local.compactMap { subscription -> TopicMetadata? in
            guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return nil }
            return TopicMetadata(
                identity: TopicIdentity(baseUrl: baseUrl, topic: topic),
                customDisplayName: subscription.customDisplayName,
                icon: subscription.icon
            )
        }
```
with:
```swift
        let syncedMetadata = synced.compactMap { syncedTopic -> TopicMetadata? in
            guard let baseUrl = syncedTopic.baseUrl, let topic = syncedTopic.topic else { return nil }
            return TopicMetadata(
                identity: TopicIdentity(baseUrl: baseUrl, topic: topic),
                customDisplayName: syncedTopic.customDisplayName,
                icon: syncedTopic.icon,
                sortRank: syncedTopic.sortRank?.doubleValue
            )
        }
        let localMetadata = local.compactMap { subscription -> TopicMetadata? in
            guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return nil }
            return TopicMetadata(
                identity: TopicIdentity(baseUrl: baseUrl, topic: topic),
                customDisplayName: subscription.customDisplayName,
                icon: subscription.icon,
                sortRank: subscription.sortRank
            )
        }
```

- [ ] **Step 4: Apply the synced rank in the `remoteOnly` block**

Replace:
```swift
        for identity in remoteOnly {
            SubscriptionManager(store: .shared).subscribe(baseUrl: identity.baseUrl, topic: identity.topic, syncToCloud: false)
            guard
                let subscription = Store.shared.getSubscription(baseUrl: identity.baseUrl, topic: identity.topic),
                let syncedTopic = synced.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic })
            else { continue }
            Store.shared.saveDisplayName(for: subscription, name: syncedTopic.customDisplayName, syncToCloud: false)
            Store.shared.saveIcon(for: subscription, icon: syncedTopic.icon, syncToCloud: false)
        }
```
with:
```swift
        for identity in remoteOnly {
            SubscriptionManager(store: .shared).subscribe(baseUrl: identity.baseUrl, topic: identity.topic, syncToCloud: false)
            guard
                let subscription = Store.shared.getSubscription(baseUrl: identity.baseUrl, topic: identity.topic),
                let syncedTopic = synced.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic })
            else { continue }
            Store.shared.saveDisplayName(for: subscription, name: syncedTopic.customDisplayName, syncToCloud: false)
            Store.shared.saveIcon(for: subscription, icon: syncedTopic.icon, syncToCloud: false)
            Store.shared.saveSortRank(for: subscription, rank: syncedTopic.sortRank?.doubleValue ?? subscription.sortRank, syncToCloud: false)
        }
```

- [ ] **Step 5: Apply the synced rank in the `metadataChanged` block**

Replace:
```swift
        for identity in metadataChanged {
            guard
                let subscription = local.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic }),
                let syncedTopic = synced.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic })
            else { continue }
            Store.shared.saveDisplayName(for: subscription, name: syncedTopic.customDisplayName, syncToCloud: false)
            Store.shared.saveIcon(for: subscription, icon: syncedTopic.icon, syncToCloud: false)
        }
```
with:
```swift
        for identity in metadataChanged {
            guard
                let subscription = local.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic }),
                let syncedTopic = synced.first(where: { $0.baseUrl == identity.baseUrl && $0.topic == identity.topic })
            else { continue }
            Store.shared.saveDisplayName(for: subscription, name: syncedTopic.customDisplayName, syncToCloud: false)
            Store.shared.saveIcon(for: subscription, icon: syncedTopic.icon, syncToCloud: false)
            Store.shared.saveSortRank(for: subscription, rank: syncedTopic.sortRank?.doubleValue ?? subscription.sortRank, syncToCloud: false)
        }
```

- [ ] **Step 6: Build and run the full test suite**

Use the `BuildProject` MCP tool, then `RunAllTests`.
Expected: build succeeds, all tests pass (this task has no new tests of its own — Tasks 8 and 9 already cover the pieces it wires together — but it must not regress the existing `TopicSyncDiffTests`/`TopicSyncStoreTests`).

- [ ] **Step 7: Commit**

```bash
git add ntfy/Persistence/TopicSyncCoordinator.swift
git commit -m "Thread sortRank through TopicSyncCoordinator reconciliation"
```

---

### Task 11: Drag-to-reorder UI — SubscriptionsObservable + SubscriptionListView

**Files:**
- Modify: `ntfy/Persistence/SubscriptionsObservable.swift`
- Modify: `ntfy/Views/Subscriptions/SubscriptionListView.swift`

**Interfaces:**
- Consumes: `Subscription.sortRank` (Task 5), `TopicRank.rank(insertingBefore:in:)` (Task 6), `Store.saveSortRank` (Task 7).
- Produces: working drag-to-reorder in the topic list.

- [ ] **Step 1: Change the fetch sort descriptor**

In `ntfy/Persistence/SubscriptionsObservable.swift`, replace:
```swift
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "topic", ascending: true)]
```
with:
```swift
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "sortRank", ascending: true)]
```

- [ ] **Step 2: Wrap the topic `ForEach` and add the reorder container**

In `ntfy/Views/Subscriptions/SubscriptionListView.swift`, in `subscriptionList`, replace:
```swift
            ForEach(subscriptionsModel.subscriptions) { subscription in
                SubscriptionItemNavView(subscription: subscription)
            }
        }
        .listStyle(.insetGrouped)
```
with:
```swift
            ForEach(subscriptionsModel.subscriptions) { subscription in
                SubscriptionItemNavView(subscription: subscription)
            }
            .reorderable()
        }
        .reorderContainer(for: Subscription.self) { difference in
            applyReorder(difference)
        }
        .listStyle(.insetGrouped)
```

- [ ] **Step 3: Add the `applyReorder` method**

In `SubscriptionListView`, add this private method (e.g. right after `pollSubscriptions()`):
```swift
    private func applyReorder(_ difference: ReorderDifference<Subscription.ID, ReorderableSingleCollectionIdentifier>) {
        guard let movedID = difference.sources.first else { return }
        let subscriptions = subscriptionsModel.subscriptions
        guard let moved = subscriptions.first(where: { $0.id == movedID }) else { return }

        let remaining = subscriptions.filter { $0.id != movedID }
        let remainingRanks = remaining.map(\.sortRank)

        let destinationIndex: Int
        switch difference.destination.position {
        case .end:
            destinationIndex = remaining.count
        case .before(let id):
            destinationIndex = remaining.firstIndex { $0.id == id } ?? remaining.count
        }

        let newRank = TopicRank.rank(insertingBefore: destinationIndex, in: remainingRanks)
        store.saveSortRank(for: moved, rank: newRank)
    }
```
(`store` is already available as `@EnvironmentObject private var store: Store` on `SubscriptionListView`.)

- [ ] **Step 4: Build**

Use the `BuildProject` MCP tool.
Expected: build succeeds. If `ReorderDifference`/`ReorderableSingleCollectionIdentifier`/`.reorderable()`/`.reorderContainer(for:)` report an unexpected signature, use `DocumentationSearch` for `reorderContainer` to confirm the exact generic parameter names and adjust `applyReorder`'s signature accordingly — the logic inside (look up moved subscription, compute remaining ranks, compute destination index, call `TopicRank.rank`, call `store.saveSortRank`) does not change.

- [ ] **Step 5: Manually verify in a simulator**

Subscribe to at least 3 topics, then drag to reorder them in the topic list. Verify:
- The new order persists after backgrounding/relaunching the app.
- Force-quit and relaunch: order is unchanged (confirms the rank was actually saved, not just reflected in the in-memory array).

- [ ] **Step 6: Commit**

```bash
git add ntfy/Persistence/SubscriptionsObservable.swift ntfy/Views/Subscriptions/SubscriptionListView.swift
git commit -m "Add drag-to-reorder for subscribed topics"
```

---

### Task 12: TopicEntity + TopicEntityQuery

**Files:**
- Create: `ntfy/AppIntents/TopicEntity.swift`
- Create: `ntfy/AppIntents/TopicEntityQuery.swift`

**Interfaces:**
- Consumes: `Store.shared.getSubscriptions()` (existing), `Subscription.displayName()` (existing).
- Produces: `TopicEntity` (with `id`, `baseUrl`, `topic`, `displayName`) and `TopicEntityQuery`, consumed by Task 13.

- [ ] **Step 1: Create `TopicEntity`**

Create `ntfy/AppIntents/TopicEntity.swift`:
```swift
import AppIntents

/// A Shortcuts-facing representation of a subscribed topic. `id` is `"\(baseUrl)|\(topic)"`,
/// matching the existing `SyncedTopic.recordName` convention used elsewhere in this codebase —
/// both exist to give the same topic a stable, deterministic identifier regardless of which
/// device or subsystem is looking at it.
struct TopicEntity: AppEntity {
    let id: String
    let baseUrl: String
    let topic: String
    let displayName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Topic"
    static var defaultQuery = TopicEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    init(subscription: Subscription) {
        let baseUrl = subscription.baseUrl ?? ""
        let topic = subscription.topic ?? ""
        self.id = "\(baseUrl)|\(topic)"
        self.baseUrl = baseUrl
        self.topic = topic
        self.displayName = subscription.displayName()
    }
}
```

- [ ] **Step 2: Create `TopicEntityQuery`**

Create `ntfy/AppIntents/TopicEntityQuery.swift`:
```swift
import AppIntents

struct TopicEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [TopicEntity] {
        let subscriptions = await MainActor.run { Store.shared.getSubscriptions() ?? [] }
        return subscriptions
            .map(TopicEntity.init)
            .filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TopicEntity] {
        let subscriptions = await MainActor.run { Store.shared.getSubscriptions() ?? [] }
        return subscriptions.map(TopicEntity.init)
    }
}
```

- [ ] **Step 3: Build**

Use the `BuildProject` MCP tool.
Expected: build succeeds. If `AppEntity`/`TypeDisplayRepresentation`/`DisplayRepresentation`/`EntityQuery` report a signature mismatch, use `DocumentationSearch` for the specific protocol/type to confirm the exact requirement and adjust — the shape (an `id: String`, a `defaultQuery`, an `entities(for:)`/`suggestedEntities()` pair backed by `Store.shared.getSubscriptions()`) does not change.

- [ ] **Step 4: Commit**

```bash
git add ntfy/AppIntents/TopicEntity.swift ntfy/AppIntents/TopicEntityQuery.swift
git commit -m "Add TopicEntity and TopicEntityQuery for App Intents"
```

---

### Task 13: PublishMessageIntent

**Files:**
- Create: `ntfy/AppIntents/PublishMessageIntent.swift`

**Interfaces:**
- Consumes: `TopicEntity` (Task 12), `Store.shared.getSubscription(baseUrl:topic:)` (existing), `Store.shared.getBasicUser(baseUrl:)` (existing), `ApiService.shared.publish(subscription:user:message:title:)` (existing).
- Produces: `PublishMessageIntent`, consumed by Task 14.

- [ ] **Step 1: Create the intent**

Create `ntfy/AppIntents/PublishMessageIntent.swift`:
```swift
import AppIntents
import Foundation

struct PublishMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Publish Message"
    static var description = IntentDescription("Publishes a message to one of your subscribed ntfy topics.")

    @Parameter(title: "Topic")
    var topic: TopicEntity

    @Parameter(title: "Message")
    var message: String

    @Parameter(title: "Title", default: nil)
    var messageTitle: String?

    func perform() async throws -> some IntentResult {
        let (subscription, user) = await MainActor.run {
            (
                Store.shared.getSubscription(baseUrl: topic.baseUrl, topic: topic.topic),
                Store.shared.getBasicUser(baseUrl: topic.baseUrl)
            )
        }
        guard let subscription else {
            throw PublishMessageIntentError.topicNoLongerSubscribed
        }
        try await ApiService.shared.publish(
            subscription: subscription,
            user: user,
            message: message,
            title: messageTitle ?? ""
        )
        return .result()
    }
}

enum PublishMessageIntentError: LocalizedError {
    case topicNoLongerSubscribed

    var errorDescription: String? {
        switch self {
        case .topicNoLongerSubscribed:
            return "This topic is no longer subscribed."
        }
    }
}
```

- [ ] **Step 2: Build**

Use the `BuildProject` MCP tool.
Expected: build succeeds. If `AppIntent`/`@Parameter`/`IntentResult`/`.result()` report a signature mismatch (e.g. `ApiService.shared` not existing — verify with a quick grep for `static let shared` in `ApiService.swift` if so), use `DocumentationSearch` for the specific symbol and adjust — the overall shape (two parameters, a main-actor hop to read `Store`, a call to the existing `publish` method, a thrown `LocalizedError` when the topic is gone) does not change.

- [ ] **Step 3: Commit**

```bash
git add ntfy/AppIntents/PublishMessageIntent.swift
git commit -m "Add PublishMessageIntent"
```

---

### Task 14: AppShortcutsProvider

**Files:**
- Create: `ntfy/AppIntents/NtfyShortcuts.swift`

**Interfaces:**
- Consumes: `PublishMessageIntent` (Task 13).
- Produces: the app's first `AppShortcutsProvider`, making `PublishMessageIntent` reachable from Shortcuts/Siri.

- [ ] **Step 1: Create the provider**

Create `ntfy/AppIntents/NtfyShortcuts.swift`:
```swift
import AppIntents

struct NtfyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PublishMessageIntent(),
            phrases: [
                "Publish a message with \(.applicationName)",
                "Send a notification with \(.applicationName)"
            ],
            shortTitle: "Publish Message",
            systemImageName: "paperplane"
        )
    }
}
```

- [ ] **Step 2: Build**

Use the `BuildProject` MCP tool.
Expected: build succeeds. No entitlements or capabilities need to be added — App Intents/`AppShortcutsProvider` work directly from the main app target.

- [ ] **Step 3: Commit**

```bash
git add ntfy/AppIntents/NtfyShortcuts.swift
git commit -m "Add AppShortcutsProvider for PublishMessageIntent"
```

---

### Task 15: Full build, full test run, manual App Intent verification

**Files:** none (verification only).

**Interfaces:**
- Consumes: everything from Tasks 1–14.
- Produces: confidence that the full feature set works together.

- [ ] **Step 1: Full build**

Use the `BuildProject` MCP tool.
Expected: build succeeds.

- [ ] **Step 2: Full test run**

Use the `RunAllTests` MCP tool.
Expected: all tests pass, including the new `TopicRankTests`, the extended `TopicSyncDiffTests`, and the extended `TopicSyncStoreTests`.

- [ ] **Step 3: Manual App Intent verification (no automated coverage exists for this — see the design spec's rationale)**

In a simulator or device running the built app:
1. Install/run the app at least once so the system extracts its App Intents metadata.
2. Open the Shortcuts app, create a new shortcut, and search for "ntfy" — confirm "Publish Message" appears as an action.
3. Add the action, pick one of your subscribed topics as the Topic parameter, type a message, and run the shortcut.
4. Confirm the message arrives as a real notification for that topic (check the app, or another subscribed device).
5. Delete a topic in the app, then re-run a previously-saved shortcut pointing at that now-deleted topic. Confirm it fails with the "This topic is no longer subscribed" error rather than crashing.

- [ ] **Step 4: Final commit (only if Step 3 required any fixes; otherwise this task has nothing to commit)**
