# Local notifications + badge for poll-fetched updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Poll-fetched messages get the same user-visible signal push-delivered messages already get (a local notification), and the app icon shows an accurate unread-count badge for both delivery paths.

**Architecture:** Extract the existing (push-path-only) local-notification-posting code out of `AppDelegate` into a standalone `LocalNotificationPoster` so `SubscriptionManager.poll` can call it directly. Make `Store`'s save path report which messages were genuinely new (not already in Core Data), so both the notification-posting and the new badge-counting logic only react to real arrivals. Badge counting itself is a direct `Notification` fetch with an `isRead == false` predicate (not relationship traversal, which caused a stale-count bug earlier this session), centralized inside `Store`'s own mutation methods so every current and future caller gets correct badge behavior for free.

**Tech Stack:** Swift, SwiftUI, Core Data, UserNotifications, a notification-service-extension (`ntfyNSE`) target sharing the same Core Data store via an App Group.

## Global Constraints

- No XCTest target exists in this project (established earlier this session) — verification is build checks plus manual checks, not automated tests.
- Badge counting must use a direct `Notification` fetch with an `isRead == false` predicate, never `Subscription.notifications` relationship traversal — that pattern caused a stale-count bug in the "All Notifications" view earlier this session (Core Data's relationship cache doesn't reliably stay in step with a direct fetch after a cross-process merge).
- `UNUserNotificationCenter.setBadgeCount(_:withCompletionHandler:)` requires iOS 17.0+. This project's deployment target is 16.0 (raised from 14/15 earlier this session). The design spec's code sample calls this API unconditionally, which will not compile at this deployment target — every task in this plan that touches it gates the call with `if #available(iOS 17.0, *)` and silently skips the badge update below iOS 17 (no crash, no fallback via `UIApplication.applicationIconBadgeNumber`, since that symbol is unavailable inside the `ntfyNSE` app extension target and this plan needs one code path that works from both targets).
- Reuse `Store.save(notificationFromMessage:baseUrl:topic:)` and `Message.from(userInfo:)` exactly as they exist today — no new dedupe logic. The existing ID-based dedupe inside `saveNotifications` already covers double-delivery (push + poll racing).
- `project.pbxproj` is manually maintained (no `PBXFileSystemSynchronizedRootGroup`) — every new Swift file needs hand-added `PBXBuildFile`/`PBXFileReference`/group-children/Sources-build-phase entries.

## File Structure

- **`ntfy/Utils/LocalNotificationPoster.swift`** (new) — the local-notification-posting logic, moved out of `AppDelegate` (which already had it, private, used only by one call site) so `SubscriptionManager` (a plain struct with no reference to `AppDelegate`) can call it too.
- **`ntfy/App/AppDelegate.swift`** — loses its three private `showNotification*` methods (moved to the file above); its background `~poll` handler simplifies since `SubscriptionManager.poll` will post notifications itself.
- **`ntfy/Persistence/Store.swift`** — `saveNotifications` (and its two public callers) start returning the subset of messages that were actually new; new `unreadNotificationCount()` and `syncBadgeCount()` methods; every notification-mutating method (`saveNotifications`, `markRead`, the four `delete(...)` variants) calls `syncBadgeCount()` after a successful mutation.
- **`ntfy/Persistence/SubscriptionManager.swift`** — `poll` gains a `notifyOnNewMessages` parameter (default `true`) and posts a local notification for genuinely-new messages; the one call site that must opt out (the catch-up poll inside `subscribe`) does so explicitly.
- **`ntfyNSE/NotificationService.swift`** — sets `content.badge` directly from `Store.unreadNotificationCount()` as a belt-and-suspenders addition alongside the `Store`-level badge sync (extensions can be suspended right after calling their completion handler, so the badge value attached to the notification content itself is the only guaranteed-atomic path).
- **`ntfy.xcodeproj/project.pbxproj`** — registers the new file in the `ntfy` target only (not `ntfyNSE` — `LocalNotificationPoster` is only used by app-target code).

---

### Task 1: Extract `LocalNotificationPoster` out of `AppDelegate`

**Files:**
- Create: `ntfy/Utils/LocalNotificationPoster.swift`
- Modify: `ntfy/App/AppDelegate.swift`
- Modify: `ntfy.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `LocalNotificationPoster.show(baseUrl: String, message: Message, completionHandler: (() -> Void)? = nil)` and `LocalNotificationPoster.showSequentially(baseUrl: String, messages: [Message], completionHandler: @escaping () -> Void)` — consumed by Task 3 (`SubscriptionManager.poll`).

This is a pure move: behavior is unchanged, only the location and (for the one call site) the calling syntax change. `AppDelegate.swift` currently has three private methods — `showNotification(_ subscription:_:completionHandler:)`, `showNotification(baseUrl:_:completionHandler:)`, and `showNotificationsSequentially(baseUrl:messages:completionHandler:)`. The first of those three (the `Subscription`-taking overload) is dead code — grep confirms nothing calls it — so it is dropped rather than moved.

- [ ] **Step 1: Create `ntfy/Utils/LocalNotificationPoster.swift`**

```swift
import UserNotifications

enum LocalNotificationPoster {
    private static let tag = "LocalNotificationPoster"

    /// Create a local notification manually (as opposed to a remote notification being generated by Firebase). We need to make the
    /// local notification look exactly like the remote one (same userInfo), so that when we tap it, the userNotificationCenter(didReceive)
    /// function has the same information available.
    static func show(baseUrl: String, message: Message, completionHandler: (() -> Void)? = nil) {
        let user = Store.shared.getUser(baseUrl: baseUrl)?.toBasicUser()
        let content = UNMutableNotificationContent()
        content.modify(message: message, baseUrl: baseUrl)
        content.attachImageIfNeeded(message: message, user: user) {
            let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil /* now */)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    Log.e(tag, "Unable to create notification", error)
                }
                completionHandler?()
            }
        }
    }

    static func showSequentially(baseUrl: String, messages: [Message], completionHandler: @escaping () -> Void) {
        guard let firstMessage = messages.first else {
            completionHandler()
            return
        }

        show(baseUrl: baseUrl, message: firstMessage) {
            showSequentially(
                baseUrl: baseUrl,
                messages: Array(messages.dropFirst()),
                completionHandler: completionHandler
            )
        }
    }
}
```

- [ ] **Step 2: Remove the three private methods from `AppDelegate.swift` and update its one call site**

Delete this block (currently lines 155-195 of `ntfy/App/AppDelegate.swift`, immediately before the closing brace of the `AppDelegate` class):

```swift
    /// Create a local notification manually (as opposed to a remote notification being generated by Firebase). We need to make the
    /// local notification look exactly like the remote one (same userInfo), so that when we tap it, the userNotificationCenter(didReceive) function
    /// has the same information available.
    private func showNotification(_ subscription: Subscription, _ message: Message, completionHandler: (() -> Void)? = nil) {
        guard let baseUrl = subscription.baseUrl else {
            Log.w(tag, "Skipping notification for subscription with missing baseUrl")
            completionHandler?()
            return
        }
        showNotification(baseUrl: baseUrl, message, completionHandler: completionHandler)
    }

    private func showNotification(baseUrl: String, _ message: Message, completionHandler: (() -> Void)? = nil) {
        let user = Store.shared.getUser(baseUrl: baseUrl)?.toBasicUser()
        let content = UNMutableNotificationContent()
        content.modify(message: message, baseUrl: baseUrl)
        content.attachImageIfNeeded(message: message, user: user) {
            let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil /* now */)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    Log.e(self.tag, "Unable to create notification", error)
                }
                completionHandler?()
            }
        }
    }

    private func showNotificationsSequentially(baseUrl: String, messages: [Message], completionHandler: @escaping () -> Void) {
        guard let firstMessage = messages.first else {
            completionHandler()
            return
        }

        showNotification(baseUrl: baseUrl, firstMessage) {
            self.showNotificationsSequentially(
                baseUrl: baseUrl,
                messages: Array(messages.dropFirst()),
                completionHandler: completionHandler
            )
        }
    }
```

Then, in `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`, find:

```swift
            subscriptionManager.poll(subscription) { messages in
                if !messages.isEmpty {
                    resultQueue.sync {
                        didReceiveNewData = true
                    }
                }
                self.showNotificationsSequentially(baseUrl: baseUrl, messages: messages) {
                    group.leave()
                }
            }
```

Replace with:

```swift
            subscriptionManager.poll(subscription) { messages in
                if !messages.isEmpty {
                    resultQueue.sync {
                        didReceiveNewData = true
                    }
                }
                LocalNotificationPoster.showSequentially(baseUrl: baseUrl, messages: messages) {
                    group.leave()
                }
            }
```

(This is a temporary state — Task 3 removes this call entirely, since `poll` will post notifications itself. Making the swap here first keeps every intermediate commit buildable.)

- [ ] **Step 3: Register the new file in `project.pbxproj` (the `ntfy` target only)**

In `ntfy.xcodeproj/project.pbxproj`:

1. In the `PBXBuildFile` section (near the other `Utils/` entries, e.g. right after the `NotificationContent.swift in Sources` lines around line 62), add:

```
		0E323F2D6E3296F12D40E1AF /* LocalNotificationPoster.swift in Sources */ = {isa = PBXBuildFile; fileRef = B442C0DC83CB8BFE0CBC891D /* LocalNotificationPoster.swift */; };
```

2. In the `PBXFileReference` section (right after the `NotificationContent.swift` file reference around line 147), add:

```
		B442C0DC83CB8BFE0CBC891D /* LocalNotificationPoster.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LocalNotificationPoster.swift; sourceTree = "<group>"; };
```

3. In the `Utils` `PBXGroup`'s `children` list (around line 325, right after `948671462841B0B20093C7A4 /* NotificationContent.swift */,`), add:

```
				B442C0DC83CB8BFE0CBC891D /* LocalNotificationPoster.swift */,
```

4. In the `ntfy` target's `PBXSourcesBuildPhase` (`9474F1B9282F2AA700CDE4DD`, **not** the `ntfyNSE` one at `9474F1E0282F3FFD00CDE4DD`), add to its `files` list:

```
				0E323F2D6E3296F12D40E1AF /* LocalNotificationPoster.swift in Sources */,
```

- [ ] **Step 4: Build check**

Run: `xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`
Expected: exit 0, no errors.

- [ ] **Step 5: Commit**

```bash
git add ntfy/Utils/LocalNotificationPoster.swift ntfy/App/AppDelegate.swift ntfy.xcodeproj/project.pbxproj
git commit -m "Extract LocalNotificationPoster out of AppDelegate"
```

---

### Task 2: `Store` reports actually-new messages and syncs the badge count

**Files:**
- Modify: `ntfy/Persistence/Store.swift`

**Interfaces:**
- Produces: `private func saveNotifications(_ messages: [Message], withSubscription subscription: Subscription) throws -> [Message]` (was `Void`); `func save(notificationsFromMessages messages: [Message], withSubscription subscription: Subscription) -> [Message]` (was `Void`) — consumed by Task 3 (`SubscriptionManager.poll`). `func unreadNotificationCount() -> Int` — consumed by Task 4 (`NotificationService.swift`). `func syncBadgeCount()` — used internally only.

- [ ] **Step 1: Add `import UserNotifications`**

`Store.swift` currently imports `Foundation`, `CoreData`, `Combine`. Add `import UserNotifications` alongside them (needed for `UNUserNotificationCenter` in Step 4 below).

- [ ] **Step 2: Make `saveNotifications` return the messages it actually inserted**

Find (private method near the bottom of the file):

```swift
    private func saveNotifications(_ messages: [Message], withSubscription subscription: Subscription) throws {
        let ids = messages.map(\.id)
        let existingRequest = Notification.fetchRequest()
        existingRequest.predicate = NSPredicate(format: "id IN %@", ids)
        let existingNotifications = try context.fetch(existingRequest)
        let existingIDs = Set(existingNotifications.compactMap(\.id))
        let newMessages = messages.filter { !existingIDs.contains($0.id) }

        guard !newMessages.isEmpty else {
            if let lastMessage = messages.last {
                subscription.lastNotificationId = lastMessage.id
                try context.save()
            }
            return
        }

        for message in newMessages {
```

Replace the signature line and the early-return with:

```swift
    private func saveNotifications(_ messages: [Message], withSubscription subscription: Subscription) throws -> [Message] {
        let ids = messages.map(\.id)
        let existingRequest = Notification.fetchRequest()
        existingRequest.predicate = NSPredicate(format: "id IN %@", ids)
        let existingNotifications = try context.fetch(existingRequest)
        let existingIDs = Set(existingNotifications.compactMap(\.id))
        let newMessages = messages.filter { !existingIDs.contains($0.id) }

        guard !newMessages.isEmpty else {
            if let lastMessage = messages.last {
                subscription.lastNotificationId = lastMessage.id
                try context.save()
            }
            return newMessages
        }

        for message in newMessages {
```

The `for message in newMessages { ... }` loop body itself is unchanged. Its closing section currently reads:

```swift
        subscription.lastNotificationId = messages.last?.id
        try context.save()
    }
```

Replace with:

```swift
        subscription.lastNotificationId = messages.last?.id
        try context.save()
        syncBadgeCount()
        return newMessages
    }
```

- [ ] **Step 3: Update `saveNotifications`'s two public callers**

Find:

```swift
    func save(notificationFromMessage message: Message, withSubscription subscription: Subscription) {
        save(notificationsFromMessages: [message], withSubscription: subscription)
    }

    func save(notificationFromMessage message: Message, baseUrl: String, topic: String) -> Bool {
        var didSave = false
        context.performAndWait {
            do {
                guard let subscription = try fetchSubscription(baseUrl: baseUrl, topic: topic) else {
                    return
                }
                try saveNotifications([message], withSubscription: subscription)
                didSave = true
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
            }
        }
        return didSave
    }

    func save(notificationsFromMessages messages: [Message], withSubscription subscription: Subscription) {
        guard !messages.isEmpty else { return }

        context.performAndWait {
            do {
                try saveNotifications(messages, withSubscription: subscription)
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
            }
        }
    }
```

Replace with:

```swift
    func save(notificationFromMessage message: Message, withSubscription subscription: Subscription) {
        _ = save(notificationsFromMessages: [message], withSubscription: subscription)
    }

    func save(notificationFromMessage message: Message, baseUrl: String, topic: String) -> Bool {
        var didSave = false
        context.performAndWait {
            do {
                guard let subscription = try fetchSubscription(baseUrl: baseUrl, topic: topic) else {
                    return
                }
                _ = try saveNotifications([message], withSubscription: subscription)
                didSave = true
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
            }
        }
        return didSave
    }

    func save(notificationsFromMessages messages: [Message], withSubscription subscription: Subscription) -> [Message] {
        guard !messages.isEmpty else { return [] }

        var newMessages: [Message] = []
        context.performAndWait {
            do {
                newMessages = try saveNotifications(messages, withSubscription: subscription)
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
            }
        }
        return newMessages
    }
```

(`save(notificationFromMessage:baseUrl:topic:)`'s public signature — still `-> Bool` — is unchanged; only its body's discarded intermediate result changed shape from `Void` to `[Message]`.)

- [ ] **Step 4: Add `unreadNotificationCount()` and `syncBadgeCount()`**

Add these two methods to the `// MARK: Notifications` section (e.g. directly after `markRead(_:)`):

```swift
    func unreadNotificationCount() -> Int {
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "isRead == %@", NSNumber(value: false))
        return (try? context.count(for: request)) ?? 0
    }

    func syncBadgeCount() {
        let count = unreadNotificationCount()
        DispatchQueue.main.async {
            guard #available(iOS 17.0, *) else { return }
            UNUserNotificationCenter.current().setBadgeCount(count)
        }
    }
```

(Per Global Constraints: `setBadgeCount` needs iOS 17+; this project's deployment target is 16.0, so the call is gated and silently skipped below iOS 17 rather than crashing or falling back to `UIApplication.applicationIconBadgeNumber`, which is unavailable inside the `ntfyNSE` extension target.)

- [ ] **Step 5: Call `syncBadgeCount()` from every other notification-mutating method**

Find:

```swift
    func delete(notification: Notification) {
        context.performAndWait {
            Log.d(Store.tag, "Deleting notification \(notification.id ?? "")")
            deleteAttachmentLocalFile(for: notification)
            context.delete(notification)
            try? context.save()
        }
    }
```

Replace with:

```swift
    func delete(notification: Notification) {
        context.performAndWait {
            Log.d(Store.tag, "Deleting notification \(notification.id ?? "")")
            deleteAttachmentLocalFile(for: notification)
            context.delete(notification)
            try? context.save()
            syncBadgeCount()
        }
    }
```

Find:

```swift
    func delete(notifications: Set<Notification>) {
        context.performAndWait {
            Log.d(Store.tag, "Deleting \(notifications.count) notification(s)")
            do {
                notifications.forEach { notification in
                    deleteAttachmentLocalFile(for: notification)
                    context.delete(notification)
                }
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot delete notification(s)", error)
                rollbackAndRefresh()
            }
        }
    }
```

Replace with:

```swift
    func delete(notifications: Set<Notification>) {
        context.performAndWait {
            Log.d(Store.tag, "Deleting \(notifications.count) notification(s)")
            do {
                notifications.forEach { notification in
                    deleteAttachmentLocalFile(for: notification)
                    context.delete(notification)
                }
                try context.save()
                syncBadgeCount()
            } catch let error {
                Log.w(Store.tag, "Cannot delete notification(s)", error)
                rollbackAndRefresh()
            }
        }
    }
```

Find:

```swift
    func delete(allNotificationsFor subscription: Subscription) {
        context.performAndWait {
            guard let notifications = subscription.notifications else { return }
            Log.d(Store.tag, "Deleting all \(notifications.count) notification(s) for subscription \(subscription.urlString())")
            do {
                notifications.forEach { notification in
                    guard let notification = notification as? Notification else { return }
                    deleteAttachmentLocalFile(for: notification)
                    context.delete(notification)
                }
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot delete notification(s)", error)
                rollbackAndRefresh()
            }
        }
    }
```

Replace with:

```swift
    func delete(allNotificationsFor subscription: Subscription) {
        context.performAndWait {
            guard let notifications = subscription.notifications else { return }
            Log.d(Store.tag, "Deleting all \(notifications.count) notification(s) for subscription \(subscription.urlString())")
            do {
                notifications.forEach { notification in
                    guard let notification = notification as? Notification else { return }
                    deleteAttachmentLocalFile(for: notification)
                    context.delete(notification)
                }
                try context.save()
                syncBadgeCount()
            } catch let error {
                Log.w(Store.tag, "Cannot delete notification(s)", error)
                rollbackAndRefresh()
            }
        }
    }
```

Find:

```swift
    func deleteAllNotifications() {
        context.performAndWait {
            guard let notifications = try? context.fetch(Notification.fetchRequest()) else { return }
            Log.d(Store.tag, "Deleting all \(notifications.count) notification(s) across all subscriptions")
            do {
                notifications.forEach { notification in
                    deleteAttachmentLocalFile(for: notification)
                    context.delete(notification)
                }
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot delete notification(s)", error)
                rollbackAndRefresh()
            }
        }
    }
```

Replace with:

```swift
    func deleteAllNotifications() {
        context.performAndWait {
            guard let notifications = try? context.fetch(Notification.fetchRequest()) else { return }
            Log.d(Store.tag, "Deleting all \(notifications.count) notification(s) across all subscriptions")
            do {
                notifications.forEach { notification in
                    deleteAttachmentLocalFile(for: notification)
                    context.delete(notification)
                }
                try context.save()
                syncBadgeCount()
            } catch let error {
                Log.w(Store.tag, "Cannot delete notification(s)", error)
                rollbackAndRefresh()
            }
        }
    }
```

Find:

```swift
    func markRead(_ notification: Notification) {
        guard !notification.isRead else { return }
        context.performAndWait {
            notification.isRead = true
            do {
                try context.save()
                Log.d(Store.tag, "Marked notification \(notification.id ?? "?") as read")
            } catch {
                Log.w(Store.tag, "Failed to save isRead for notification \(notification.id ?? "?")", error)
            }
        }
    }
```

Replace with:

```swift
    func markRead(_ notification: Notification) {
        guard !notification.isRead else { return }
        context.performAndWait {
            notification.isRead = true
            do {
                try context.save()
                Log.d(Store.tag, "Marked notification \(notification.id ?? "?") as read")
                syncBadgeCount()
            } catch {
                Log.w(Store.tag, "Failed to save isRead for notification \(notification.id ?? "?")", error)
            }
        }
    }
```

Find:

```swift
    func delete(subscription: Subscription) {
        context.performAndWait {
            if let notifications = subscription.notifications {
                notifications.forEach { notification in
                    guard let notification = notification as? Notification else { return }
                    deleteAttachmentLocalFile(for: notification)
                }
            }
            context.delete(subscription)
            try? context.save()
        }
    }
```

Replace with:

```swift
    func delete(subscription: Subscription) {
        context.performAndWait {
            if let notifications = subscription.notifications {
                notifications.forEach { notification in
                    guard let notification = notification as? Notification else { return }
                    deleteAttachmentLocalFile(for: notification)
                }
            }
            context.delete(subscription)
            try? context.save()
            syncBadgeCount()
        }
    }
```

- [ ] **Step 6: Build check**

Run: `xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`
Expected: exit 0, no errors.

- [ ] **Step 7: Manual check**

On a device/simulator running iOS 17+, with at least one unread notification already in the store: open the topic to mark it read (or delete a notification), then check the Home Screen — the app icon's badge number should decrement to match. (On iOS <17 simulators, per Global Constraints, the badge silently does not update — this is expected, not a bug, given this plan's scope.)

- [ ] **Step 8: Commit**

```bash
git add ntfy/Persistence/Store.swift
git commit -m "Store reports actually-new messages and syncs the app badge"
```

---

### Task 3: `SubscriptionManager.poll` notifies on genuinely new messages

**Files:**
- Modify: `ntfy/Persistence/SubscriptionManager.swift`
- Modify: `ntfy/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `LocalNotificationPoster.showSequentially(baseUrl:messages:completionHandler:)` (Task 1); `Store.save(notificationsFromMessages:withSubscription:) -> [Message]` (Task 2).

Note on deviation from the design spec: the spec's literal code sample for this step drops the existing `Log.e(tag, "Polling failed", error)` line entirely (it collapses the "API call failed" and "API call succeeded with zero messages" cases into one `guard`). That would delete a real error log for genuine poll failures. The code below preserves that distinction — same new behavior (notify only on genuinely-new messages, with an opt-out), without losing the existing failure log.

- [ ] **Step 1: Update `poll`'s two overloads**

Find (in `SubscriptionManager.swift`):

```swift
    func poll(_ subscription: Subscription) {
        poll(subscription) { _ in }
    }
    
    func poll(_ subscription: Subscription, completionHandler: @escaping ([Message]) -> Void) {
        // This is a bit of a hack but it prevents us from polling dead subscriptions
        if (subscription.baseUrl == nil) {
            Log.d(tag, "Attempting to poll dead subscription failed")
            completionHandler([])
            return
        }
        
        let user = store.getUser(baseUrl: subscription.baseUrl!)?.toBasicUser()
        Log.d(tag, "Polling from \(subscription.urlString()) with user \(user?.username ?? "anonymous")")
        ApiService.shared.poll(subscription: subscription, user: user) { messages, error in
            guard let messages = messages else {
                Log.e(tag, "Polling failed", error)
                completionHandler([])
                return
            }
            Log.d(tag, "Polling success, \(messages.count) new message(s)", messages)
            if !messages.isEmpty {
                store.save(notificationsFromMessages: messages, withSubscription: subscription)
            }
            completionHandler(messages)
        }
    }
```

Replace with:

```swift
    func poll(_ subscription: Subscription, notifyOnNewMessages: Bool = true) {
        poll(subscription, notifyOnNewMessages: notifyOnNewMessages) { _ in }
    }
    
    func poll(_ subscription: Subscription, notifyOnNewMessages: Bool = true, completionHandler: @escaping ([Message]) -> Void) {
        // This is a bit of a hack but it prevents us from polling dead subscriptions
        if (subscription.baseUrl == nil) {
            Log.d(tag, "Attempting to poll dead subscription failed")
            completionHandler([])
            return
        }
        
        let user = store.getUser(baseUrl: subscription.baseUrl!)?.toBasicUser()
        Log.d(tag, "Polling from \(subscription.urlString()) with user \(user?.username ?? "anonymous")")
        ApiService.shared.poll(subscription: subscription, user: user) { messages, error in
            guard let messages = messages else {
                Log.e(tag, "Polling failed", error)
                completionHandler([])
                return
            }
            Log.d(tag, "Polling success, \(messages.count) new message(s)", messages)
            guard !messages.isEmpty else {
                completionHandler([])
                return
            }
            let newMessages = store.save(notificationsFromMessages: messages, withSubscription: subscription)
            guard notifyOnNewMessages, !newMessages.isEmpty, let baseUrl = subscription.baseUrl else {
                completionHandler(newMessages)
                return
            }
            LocalNotificationPoster.showSequentially(baseUrl: baseUrl, messages: newMessages) {
                completionHandler(newMessages)
            }
        }
    }
```

- [ ] **Step 2: Opt the catch-up poll (inside `subscribe`) out of notifying**

Find (in `subscribe(baseUrl:topic:)`):

```swift
        let subscription = store.saveSubscription(baseUrl: normalizedBaseUrl, topic: topic)
        poll(subscription)
```

Replace with:

```swift
        let subscription = store.saveSubscription(baseUrl: normalizedBaseUrl, topic: topic)
        poll(subscription, notifyOnNewMessages: false)
```

Every other existing call site (`SubscriptionListView.pollSubscriptions()`, `AllNotificationsView`'s pull-to-refresh, `NotificationListView`'s pull-to-refresh) needs no changes — they already call the plain `poll(_ subscription:)` convenience method, which now defaults to `notifyOnNewMessages: true`.

- [ ] **Step 3: Simplify `AppDelegate`'s background `~poll` handler**

`poll` now posts notifications itself, so the handler's own `LocalNotificationPoster.showSequentially` call (added in Task 1 Step 2) would double-post. Find, in `ntfy/App/AppDelegate.swift`'s `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`:

```swift
        subscriptions.forEach { subscription in
            group.enter()
            guard let baseUrl = subscription.baseUrl else {
                Log.w(tag, "Skipping background poll notification for subscription with missing baseUrl")
                group.leave()
                return
            }
            subscriptionManager.poll(subscription) { messages in
                if !messages.isEmpty {
                    resultQueue.sync {
                        didReceiveNewData = true
                    }
                }
                LocalNotificationPoster.showSequentially(baseUrl: baseUrl, messages: messages) {
                    group.leave()
                }
            }
        }
```

Replace with:

```swift
        subscriptions.forEach { subscription in
            group.enter()
            guard subscription.baseUrl != nil else {
                Log.w(tag, "Skipping background poll notification for subscription with missing baseUrl")
                group.leave()
                return
            }
            subscriptionManager.poll(subscription) { newMessages in
                if !newMessages.isEmpty {
                    resultQueue.sync {
                        didReceiveNewData = true
                    }
                }
                group.leave()
            }
        }
```

(`baseUrl` was only needed for the now-removed `showNotificationsSequentially`/`LocalNotificationPoster.showSequentially` call, so the guard no longer needs to bind it. The completion handler's parameter is renamed `messages` → `newMessages` here to make it explicit that, as of Task 2, this is the actually-new subset, not the raw poll response — `didReceiveNewData` bookkeeping now reacts to genuine new data instead of "the server returned something," which was itself the second bug this whole plan traces back to.)

- [ ] **Step 4: Build check**

Run: `xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`
Expected: exit 0, no errors.

- [ ] **Step 5: Manual check — no notification burst on initial subscribe**

Subscribe to a topic that already has message history on the server. Confirm: the topic's messages become visible in the list (existing behavior, unaffected), and no local notification fires for any of them.

- [ ] **Step 6: Manual check — poll posts a notification for a genuinely new message**

With an existing subscription, post a new message to that topic on the server, then pull-to-refresh in the app (or use `SubscriptionListView`'s refresh). Confirm a local notification appears, and (iOS 17+) the app icon badge increments.

- [ ] **Step 7: Commit**

```bash
git add ntfy/Persistence/SubscriptionManager.swift ntfy/App/AppDelegate.swift
git commit -m "SubscriptionManager.poll notifies on genuinely new messages"
```

---

### Task 4: Push path sets the notification's badge directly

**Files:**
- Modify: `ntfyNSE/NotificationService.swift`

**Interfaces:**
- Consumes: `Store.unreadNotificationCount() -> Int` (Task 2).

This is intentionally redundant with the `Store`-level `syncBadgeCount()` hook from Task 2 (which already fires for the push path too, since `handleMessage` calls `store?.save(notificationFromMessage:baseUrl:topic:)`, which funnels through the same `saveNotifications`): a notification-service-extension can be suspended immediately after calling its completion handler, and `content.badge` is guaranteed to apply atomically as part of notification delivery, whereas the async `setBadgeCount()` call could theoretically be cut off by that suspension.

- [ ] **Step 1: Set `content.badge` in `handleMessage`**

Find (in `ntfyNSE/NotificationService.swift`):

```swift
    private func handleMessage(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ baseUrl: String, _ message: Message, _ contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Save notification first so attachment downloads can update persistent state.
        guard store?.save(notificationFromMessage: message, baseUrl: baseUrl, topic: message.topic) == true else {
            Log.w(tag, "Subscription \(topicUrl(baseUrl: baseUrl, topic: message.topic)) unknown")
            contentHandler(request.content)
            return
        }
        let user = store?.getBasicUser(baseUrl: baseUrl)
        content.modify(message: message, baseUrl: baseUrl)
        content.attachImageIfNeeded(message: message, user: user) {
            contentHandler(content)
        }
    }
```

Replace with:

```swift
    private func handleMessage(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ baseUrl: String, _ message: Message, _ contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Save notification first so attachment downloads can update persistent state.
        guard store?.save(notificationFromMessage: message, baseUrl: baseUrl, topic: message.topic) == true else {
            Log.w(tag, "Subscription \(topicUrl(baseUrl: baseUrl, topic: message.topic)) unknown")
            contentHandler(request.content)
            return
        }
        content.badge = NSNumber(value: store?.unreadNotificationCount() ?? 0)
        let user = store?.getBasicUser(baseUrl: baseUrl)
        content.modify(message: message, baseUrl: baseUrl)
        content.attachImageIfNeeded(message: message, user: user) {
            contentHandler(content)
        }
    }
```

- [ ] **Step 2: Build check**

Run: `xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`
Expected: exit 0, no errors.

- [ ] **Step 3: Manual check (best-effort)**

If push is functional in the current test environment, deliver a push-triggered message and confirm the app icon badge updates. (Push has not been reliably functional in this session's test environment so far this branch — if it still isn't, this check is a no-op; the `Store`-level `syncBadgeCount()` from Task 2 already covers the push path's badge update through the shared `saveNotifications` funnel, so this step is redundancy on top of already-covered behavior, not the only path being verified.)

- [ ] **Step 4: Commit**

```bash
git add ntfyNSE/NotificationService.swift
git commit -m "NSE sets notification badge directly from unread count"
```

---

## Self-Review Notes

- **Spec coverage:** `LocalNotificationPoster` extraction (Task 1), `saveNotifications`/its callers returning actually-new messages (Task 2 Steps 2-3), badge count infrastructure + wiring into every mutation method (Task 2 Steps 4-5), `poll`'s `notifyOnNewMessages` parameter and the `subscribe` opt-out (Task 3), `content.badge` on the push path (Task 4) — all five spec sections covered.
- **Deviations from the design spec, both intentional and necessary:**
  1. `syncBadgeCount()`'s call to `UNUserNotificationCenter.setBadgeCount(_:)` is gated behind `if #available(iOS 17.0, *)` — the spec's literal sample calls it unconditionally, which does not compile at this project's iOS 16.0 deployment target.
  2. Task 3's `poll` rewrite preserves the existing `Log.e(tag, "Polling failed", error)` line for genuine API failures, which the spec's literal sample silently drops by collapsing the nil-response and empty-response cases into a single guard.
- **Type consistency:** `LocalNotificationPoster.show(baseUrl:message:completionHandler:)` / `.showSequentially(baseUrl:messages:completionHandler:)` (Task 1) are called with matching argument labels and types in Task 3's rewritten `poll`. `Store.save(notificationsFromMessages:withSubscription:) -> [Message]` (Task 2) is consumed correctly in Task 3 (`let newMessages = store.save(...)`). `Store.unreadNotificationCount() -> Int` (Task 2) matches its usage in Task 4 (`NSNumber(value: store?.unreadNotificationCount() ?? 0)`).
- **No test target:** every task substitutes a build check plus a concrete manual verification for the automated test cycle this skill normally prescribes, per the spec's stated project constraint (also true of the notification-delivery-fixes plan executed just before this one).
