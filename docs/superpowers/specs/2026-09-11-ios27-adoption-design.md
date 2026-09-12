# iOS 27 feature adoption

## Context

Following a performance audit of the message list, the user asked what iOS 27 SwiftUI/App Intents
features are worth adopting in the app. Four independent pieces were scoped:

1. Replace the `showAlert`/`activeAlert` enum + `switch` pattern in `NotificationListView.swift`
   (and the identical pattern in `SubscriptionListView.swift`'s unsubscribe confirmation) with
   SwiftUI 27's `alert(_:item:actions:message:)`.
2. Add `.toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)` to `NotificationListView`'s
   toolbar.
3. Add drag-to-reorder for subscribed topics (`SubscriptionListView`) using SwiftUI 27's
   `.reorderable()`/`.reorderContainer(for:)`, with the order synced across devices via the
   existing iCloud topic-sync pipeline (`TopicSyncStore`/`TopicSyncCoordinator`/`TopicSyncDiff`,
   see `docs/superpowers/specs/2026-08-21-icloud-topic-sync-design.md`).
4. Add a first App Intent — publish a message to a topic — with `AppShortcutsProvider` so it's
   reachable from Shortcuts/Siri. The app currently has zero App Intents code.

All four require iOS 27 APIs; the app's deployment target is currently iOS 26.0. Decided during
brainstorming: bump the deployment target to iOS 27.0 across all targets rather than write
`@available`-gated dual paths for three separate features. This drops iOS 26 device support.

## Design

### 0. Deployment target

Set `IPHONEOS_DEPLOYMENT_TARGET = 27.0` for every target in `ntfy.xcodeproj/project.pbxproj`
(`ntfy`, `ntfyNSE`, and any test targets). No `@available`/`if #available` gating anywhere in this
work — all four features assume iOS 27 unconditionally.

### 1. `alert(item:)` refactor

**`NotificationListView.swift`:** replace `@State private var showAlert = false` and
`@State private var activeAlert: ActiveAlert = .clear` (and the module-level `enum ActiveAlert`)
with:

```swift
private enum PendingAlert: Identifiable {
    case clear, unsubscribe, selected
    var id: Self { self }
}

@State private var pendingAlert: PendingAlert?
```

Every call site that did `showAlert = true; activeAlert = .x` becomes `pendingAlert = .x`. The
single `.alert(isPresented:) { switch ... }` becomes:

```swift
.alert(alertTitle(for: pendingAlert), item: $pendingAlert) { alert in
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
    case .clear: Text("Do you really want to delete all of the notifications in this topic?")
    case .unsubscribe: Text("Do you really want to unsubscribe from this topic and delete all of the notifications you received?")
    case .selected: Text("Do you really want to delete these selected notifications?")
    }
}
```

(`alertTitle(for:)` is a small helper returning "Clear notifications" / "Unsubscribe" / "Delete" —
the three titles the current `switch` already uses. Exact same copy, roles, and actions as today;
only the presentation mechanism changes.)

No change to copy, button roles, or the actions themselves (`deleteAll`, `unsubscribe`,
`deleteSelected`) — this is a mechanical presentation-mechanism swap.

**`SubscriptionListView.swift` (`SubscriptionItemNavView`):** same treatment for
`@State private var unsubscribeAlert = false`, replaced with
`@State private var pendingUnsubscribe: Subscription?` (no enum needed, single alert case), driving
`.alert("Unsubscribe", item: $pendingUnsubscribe) { subscription in ... }`.

### 2. Toolbar minimize

In `NotificationListView.swift`'s `notificationList`, add:

```swift
.toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
```

No other toolbar structure changes — the existing principal title + trailing "More" menu /
edit button stay as-is.

### 3. Drag-to-reorder topics, synced via iCloud

#### Data model

- `ntfy/Persistence/ntfy.xcdatamodeld` (`Subscription` entity): add
  `<attribute name="sortRank" attributeType="Double" defaultValueString="0"/>` (non-optional,
  defaulted — qualifies for automatic lightweight migration).
- `ntfy/Persistence/TopicSync.xcdatamodeld` (`SyncedTopic` entity): add
  `<attribute name="sortRank" optional="YES" attributeType="Double"/>` — must be optional, per the
  existing hard rule documented at the top of that model file (CloudKit mirroring rejects
  non-optional/non-defaulted attributes).
- Both containers already have `shouldMigrateStoreAutomatically`/`shouldInferMappingModelAutomatically`
  set, so no custom mapping model is needed for either additive attribute.

#### One-time backfill for existing installs

On `Store.init`, after the persistent store loads, if `UserDefaults.standard` lacks a
`"Store.didBackfillSortRank"` flag: fetch all `Subscription`s sorted the way
`SubscriptionsObservable` sorts them today (`topic` ascending), assign
`sortRank = 0, 1, 2, …` in that order, save, and set the flag. This makes the migration invisible —
nobody's topic list visibly reshuffles the moment they update.

If two devices each run this backfill independently before either has synced, they may briefly
upload different rank assignments for the same topics; this converges the same way a concurrent
rename already does today, via `SyncedTopic.lastModified` last-write-wins in
`TopicSyncStore.upsert`/`deduplicate`. Not a new failure mode — reusing an existing guarantee.

#### Assigning ranks

- New subscriptions: `Store.saveSubscription(baseUrl:topic:)` computes
  `sortRank = (current max sortRank across all Subscriptions) + 1` inside the same
  `context.performAndWait` block, so new topics land at the end.
- Reordering: a small pure helper (unit-testable, no Core Data dependency) computes a moved item's
  new rank from its new neighbors:
  - Between two items: `newRank = (beforeRank + afterRank) / 2`.
  - At the very front: `newRank = firstRank - 1`.
  - At the very end: `newRank = lastRank + 1`.

  This only ever rewrites the moved row's own `sortRank` — never the whole list — matching the
  "one field, one conflict surface" shape the existing sync already relies on for
  `customDisplayName`/`icon`.

  `ReorderDifference.sources` is technically a list (multi-item drag), but `SubscriptionListView`
  has no multi-select UI, so the `move` closure only ever needs to handle exactly one source id in
  practice. The closure asserts/logs and takes the first id if `sources.count != 1` rather than
  handling a real multi-item reorder — this app has no path that produces one today.

- New `Store.saveSortRank(for subscription: Subscription, rank: Double, syncToCloud: Bool = true)`,
  mirroring `saveIcon`/`saveDisplayName` exactly: `context.performAndWait { subscription.sortRank = rank; try? context.save() }`,
  then (outside the `#if !NTFY_NSE` guard, same as the other two) calls
  `TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)` when `syncToCloud`.

#### Sync plumbing

- `TopicSyncDiff.swift`: add `sortRank: Double?` to `TopicMetadata`. Extend `metadataChanged`'s
  existing `changed` check (`customDisplayName != ... || icon != ...`) with `|| sortRank != ...` —
  same direct-inequality comparison already used for the other two optional fields, no special-casing
  of `nil`.
- `TopicSyncStore.upsert(baseUrl:topic:customDisplayName:icon:)` gains a `sortRank: Double?`
  parameter, written to `SyncedTopic.sortRank`.
- `TopicSyncCoordinator.localSubscriptionDidChange`: passes `subscription.sortRank` through to
  `upsert`.
- `TopicSyncCoordinator.reconcileFromRemote`: both the `remoteOnly`-apply block and the
  `metadataChanged`-apply block gain a call to
  `Store.shared.saveSortRank(for: subscription, rank: syncedTopic.sortRank ?? subscription.sortRank, syncToCloud: false)`
  right alongside the existing `saveDisplayName`/`saveIcon` calls. The `?? subscription.sortRank`
  fallback covers a `SyncedTopic` row written before this feature shipped (no `sortRank` yet) —
  leaves the local rank untouched instead of clobbering it with a meaningless value.

#### UI — `SubscriptionListView.swift`

- Change `SubscriptionsObservable`'s fetch sort descriptor from `NSSortDescriptor(key: "topic", ascending: true)`
  to `NSSortDescriptor(key: "sortRank", ascending: true)`.
- Wrap the topic `ForEach` with `.reorderable()` and add
  `.reorderContainer(for: Subscription.self) { difference in ... }` to the enclosing `List`
  (`Subscription` already conforms to `Identifiable` via `NSManagedObject`, matching the existing
  bare `ForEach(subscriptionsModel.subscriptions)` call, which only compiles because of that).
- The `move` closure's only job is to persist the new rank — it does **not** need to mutate any
  local array itself, unlike the reference implementation's generic example (which mutates a
  `@State` array): `SubscriptionsObservable` is backed by an `NSFetchedResultsController`, so once
  `sortRank` is saved, the FRC's delegate republishes the freshly-sorted `subscriptions` array on
  its own. The closure: look up the moved `Subscription` by id, compute its new rank against its
  new neighbors (using the helper above), call `store.saveSortRank(for:rank:)`.

#### Tests

- `TopicSyncDiffTests.swift`: cases for `metadataChanged` flagging a `sortRank`-only difference,
  plus nil/non-nil combinations.
- `TopicSyncStoreTests.swift`: extend the `upsert` round-trip coverage to include `sortRank`.
- New test file for the rank-midpoint helper: front/middle/end insertion, and the single-item-list
  edge case.

### 4. App Intent: publish a message to a topic

New group `ntfy/AppIntents/`:

- **`TopicEntity.swift`** — `struct TopicEntity: AppEntity` wrapping a topic identity:
  `id: String` (format `"\(baseUrl)|\(topic)"`, matching the existing `SyncedTopic.recordName`
  convention already used elsewhere in this codebase), plus `baseUrl`, `topic`, and a
  `displayName` (from `Subscription.displayName()`) for display in Shortcuts.
  `static var typeDisplayRepresentation: TypeDisplayRepresentation = "Topic"`.
- **`TopicEntityQuery.swift`** — `struct TopicEntityQuery: EntityQuery`:
  - `entities(for identifiers: [String]) async throws -> [TopicEntity]`: resolves against
    `Store.shared.getSubscriptions()`, matching on the composed id.
  - `suggestedEntities() async throws -> [TopicEntity]`: returns every subscribed topic — there's
    no natural "default" narrower than "all my topics" for a personal subscription list.
- **`PublishMessageIntent.swift`** — `struct PublishMessageIntent: AppIntent`:
  - `@Parameter var topic: TopicEntity`
  - `@Parameter var message: String`
  - `@Parameter(default: nil) var title: String?`
  - `perform() async throws -> some IntentResult`: hops to the main actor to look up the live
    `Subscription` (via `Store.shared.getSubscription(baseUrl:topic:)`) and the optional
    `BasicUser` (via `Store.shared.getUser(baseUrl:)`), then calls
    `ApiService.shared.publish(subscription:user:message:title:)`. Throws a small
    `LocalizedError` (e.g. "This topic is no longer subscribed") if the subscription was removed
    since the shortcut was set up.
- **`NtfyShortcuts.swift`** — `struct NtfyShortcuts: AppShortcutsProvider`, one `AppShortcut` for
  `PublishMessageIntent` with a couple of phrases built with `\(.applicationName)`.

No new entitlements, capabilities, or targets — App Intents work directly from the main app
target via `import AppIntents`.

**Testing:** no automated coverage for `perform()` in this first pass. `AppIntentsTesting` runs
out-of-process against an installed build, which is more test infrastructure than seems justified
for the first intent this app has ever had. Verification is manual, via the Shortcuts app, after
building. Flagged here as a known gap rather than silently skipped.

## Out of scope

- The "visibilityPriority / pinned trailing item" toolbar ideas floated earlier — dropped, since
  `NotificationListView`'s toolbar only has one trailing item today and nothing needs pinning.
- Additional App Intents (mark-all-read, open-topic) — deferred; only the publish intent was
  chosen for this pass.
- `AsyncImage(request:)` / `asyncImageURLSession` — not applicable; attachment images are already
  local files loaded through the custom `NotificationAttachmentImageLoader`, not `AsyncImage`.
