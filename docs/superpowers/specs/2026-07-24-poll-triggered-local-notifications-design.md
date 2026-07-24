# Local notifications + badge for poll-fetched updates

## Context

Push-delivered messages already show a system notification, via the `ntfyNSE` notification-service-extension (`NotificationService.swift`) building a `UNMutableNotificationContent` and handing it back to iOS. Messages picked up by the app's own HTTP polling (`SubscriptionManager.poll`) do not — they're saved straight to Core Data with no user-visible signal beyond the in-app unread indicators added earlier in this branch. This was directly observed and diagnosed earlier in this session: with push non-functional in a test environment, new messages only became visible after something forced a poll (switching tabs, pull-to-refresh), and even then, nothing told the user a new message had arrived — no banner, no badge.

Separately, there is no app-icon badge (the home-screen number) at all today, for either push or poll paths.

This spec covers both gaps: local notifications for poll-fetched messages, and app-icon badge management for both push and poll paths.

## Prior art reviewed

[binwiederhier/ntfy-ios#24](https://github.com/binwiederhier/ntfy-ios/pull/24) ("Adding an 'unread notification' indicator and unread count badge to the app icon", open, unmerged) attempts the badge half of this. Two things taken from reviewing it:

- **Avoid:** its `totalUnreadNotificationCount` sums each `Subscription`'s `notifications` relationship. This is the same relationship-traversal pattern that caused a stale-count bug in this app's "All Notifications" view earlier this session (Core Data's relationship cache doesn't reliably stay in step with a direct fetch after a cross-process merge). This spec uses a direct `Notification` fetch with an `isRead == false` predicate instead — the same fix already proven correct for that earlier bug.
- **Borrow:** the PR is thorough about *where* the badge must update — not just new arrivals, but unsubscribing and every notification-deletion path too. This spec adopts that same coverage, but centralizes it inside `Store`'s own mutation methods rather than requiring every UI call site to remember to call an updater (the PR's approach, which already appears to miss at least one delete path).

## Design

### 1. Extract local-notification posting out of `AppDelegate`

`AppDelegate.swift` already has private `showNotification`/`showNotificationsSequentially` methods, used today only by the existing "~poll" background-fetch handler. They build a `UNMutableNotificationContent` via the same `.modify(message:baseUrl:)` extension the push extension uses, then post it via `UNUserNotificationCenter.current().add(...)`. Nothing in them depends on `AppDelegate` state.

Move them, unchanged in behavior, into a new file `ntfy/Utils/LocalNotificationPoster.swift` as static methods, so they're callable from `SubscriptionManager` (a plain struct with no reference to `AppDelegate`) as well as from `AppDelegate` itself:

```swift
enum LocalNotificationPoster {
    static func show(baseUrl: String, message: Message, completionHandler: (() -> Void)? = nil)
    static func showSequentially(baseUrl: String, messages: [Message], completionHandler: @escaping () -> Void)
}
```

### 2. Make `Store` report which messages were actually new

`Store.saveNotifications(_:withSubscription:)` (private) already computes `newMessages` (the subset not already present by ID) before inserting — it just doesn't return them. Change its return type from `Void` to `[Message]`, returning that same `newMessages` array. Propagate this through its two public callers:

- `save(notificationsFromMessages:withSubscription:)` → returns `[Message]` (was `Void`)
- `save(notificationFromMessage:baseUrl:topic:)` → signature unchanged (still returns `Bool` for "did this succeed", used by the NSE only to decide whether to continue building notification content); internally just stops discarding `saveNotifications`'s return value.

This closes a latent gap in the *existing* background-poll notification path: today it posts a notification for every message the poll API returns, not only the ones that were actually new to the database. In the rare case a message arrives via both push and poll near-simultaneously, that could double-notify. Threading through the actually-new list fixes this for both the existing background path and the new one this spec adds.

### 3. `SubscriptionManager.poll` posts notifications for genuinely new messages, with an opt-out

```swift
func poll(_ subscription: Subscription, notifyOnNewMessages: Bool = true) {
    poll(subscription, notifyOnNewMessages: notifyOnNewMessages) { _ in }
}

func poll(_ subscription: Subscription, notifyOnNewMessages: Bool = true, completionHandler: @escaping ([Message]) -> Void) {
    // ...existing setup...
    ApiService.shared.poll(subscription: subscription, user: user) { messages, error in
        guard let messages, !messages.isEmpty else {
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

`subscribe(baseUrl:topic:)`'s initial catch-up poll changes its one call from `poll(subscription)` to `poll(subscription, notifyOnNewMessages: false)` — this is the only call site that opts out, so a newly-subscribed topic's entire visible history doesn't fire a burst of notifications. Every other existing call site (`SubscriptionListView.pollSubscriptions()`, `AllNotificationsView`'s pull-to-refresh, `NotificationListView`'s pull-to-refresh) needs **no changes at all** — they already call the plain `poll(_ subscription:)` convenience method, which now defaults to notifying.

`AppDelegate`'s existing background-fetch handler (the "~poll" remote-notification handler) already calls the completion-handler overload of `poll`. Since `poll` now posts notifications itself, remove the handler's own `showNotificationsSequentially` call — it would otherwise double-post. The handler keeps its `didReceiveNewData` bookkeeping (based on whether `messages` was non-empty) and just calls `group.leave()`.

### 4. Badge count

Add to `Store`:

```swift
func unreadNotificationCount() -> Int {
    let request = Notification.fetchRequest()
    request.predicate = NSPredicate(format: "isRead == %@", NSNumber(value: false))
    return (try? context.count(for: request)) ?? 0
}

func syncBadgeCount() {
    let count = unreadNotificationCount()
    DispatchQueue.main.async {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
```

Direct predicate-based fetch, not relationship traversal — see "Prior art reviewed" above.

Call `syncBadgeCount()` from inside `Store`'s own mutation methods, so every current and future caller gets correct badge behavior automatically rather than needing to remember to call an updater themselves:

- `saveNotifications(_:withSubscription:)` — after a successful save with a non-empty `newMessages` (covers both the NSE's `save(notificationFromMessage:baseUrl:topic:)` and `SubscriptionManager.poll`'s `save(notificationsFromMessages:withSubscription:)`, i.e. both push and poll paths, in one place)
- `markRead(_:)` — after successfully flipping `isRead`
- `delete(notification:)`, `delete(notifications:)`, `delete(allNotificationsFor:)`, `deleteAllNotifications()`, `delete(subscription:)` — after each successful delete (removing unread notifications, or a whole subscription's worth, can reduce the count)

### 5. Push path (`NotificationService.swift`)

`handleMessage` already calls `store?.save(notificationFromMessage:baseUrl:topic:)`, which (per #4) now calls `syncBadgeCount()` as a side effect via the shared `saveNotifications` path — `UNUserNotificationCenter.setBadgeCount()` is documented to work from extensions and isn't tied to a `UIApplication` instance.

In addition, set `content.badge` directly on the notification content before calling `contentHandler`, using the same `unreadNotificationCount()`:

```swift
if store?.save(notificationFromMessage: message, baseUrl: baseUrl, topic: message.topic) == true {
    content.badge = NSNumber(value: store?.unreadNotificationCount() ?? 0)
}
```

This is intentionally redundant with the `Store`-level hook: a notification-service-extension can be suspended immediately after calling its completion handler, and `content.badge` is guaranteed to apply atomically as part of notification delivery, whereas the async `setBadgeCount()` call could theoretically be cut off by that suspension. Every other path (poll, markRead, deletes) relies solely on the `Store`-level hook, since there's no notification content to attach a badge to.

## Out of scope

- No changes to notification *content* formatting — reuses `UNMutableNotificationContent.modify(message:baseUrl:)` exactly as the push path already does.
- No manual "mark all as read" UI (PR #24 adds one; not requested here, and `markRead` already fires automatically via `NotificationRowView.onAppear`).
- No de-duplication beyond what's described above; the residual race window (a message delivered via push and poll in the same narrow moment before either save commits) is a pre-existing, low-probability risk not introduced by this change.

## Testing

No XCTest target exists in this project (established earlier this session) — verification is build checks plus manual checks:

- Build check after each change.
- Manual: subscribe to a topic with existing history, confirm no notifications fire for the initial catch-up, confirm the topic's messages are visible.
- Manual: with an existing subscription, trigger a poll (pull-to-refresh) after a new message has been posted on the server; confirm a local notification appears and the app icon badge increments.
- Manual: open the topic and let it auto-mark-read; confirm the badge decrements to match.
- Manual: delete/clear notifications; confirm the badge decrements accordingly.
- Manual: a push-delivered message (if push is functional in the test environment) also updates the badge.
