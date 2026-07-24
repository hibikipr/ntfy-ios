# Notification delivery bug fixes

## Context

While reviewing [binwiederhier/ntfy-ios#28](https://github.com/binwiederhier/ntfy-ios/pull/28) for ideas worth incorporating, two real, currently-present bugs in this fork's `AppDelegate.swift` were confirmed by reading the current code (not assumed from the PR's older baseline):

1. **`userNotificationCenter(willPresent:)` never saves the notification to Core Data.** It only shows the banner. The notification-service-extension (NSE) is what normally saves incoming messages to Core Data — but NSE does not run on the iOS Simulator (a documented Apple limitation), which is the only environment used for testing this fork so far this session. A message delivered while the app is foregrounded and NSE is skipped shows a banner but never appears in the topic list.
2. **Firebase topic re-subscription only happens once, on token refresh** (`messaging(_:didReceiveRegistrationToken:)`). If a subscription silently fails (network blip, token rotation edge case), there is no retry path until the token itself changes again, which is rare.

A third, minor issue: `FirebaseConfiguration.shared.setLoggerLevel(.max)` is very noisy in production logs; PR #28 turns it down to `.warning`.

This spec fixes all three, adapted to this fork's current code (which has diverged from PR #28's baseline in ways that make several of its other fixes — the `DispatchGroup` background-fetch timing, idempotent-save-by-ID — already redundant here; see the PR-survey conversation this spec follows from).

## Design

### 1. Extract a reusable `AppDelegate.subscribeToFirebaseTopics()`

Today, `messaging(_:messaging:didReceiveRegistrationToken:)` inline-subscribes to the `~poll` topic and then loops over `store.getSubscriptions()` to subscribe to each one's Firebase topic. Extract this into a method:

```swift
func subscribeToFirebaseTopics() {
    Messaging.messaging().subscribe(toTopic: pollTopic) { error in
        if let error {
            Log.e(self.tag, "Firebase subscribe failed for \(self.pollTopic)", error)
        } else {
            Log.d(self.tag, "Firebase subscribe succeeded for \(self.pollTopic)")
        }
    }

    let store = Store.shared
    store.getSubscriptions()?.forEach { subscription in
        guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return }
        let firebaseTopicName = firebaseTopic(baseUrl: baseUrl, topic: topic)
        Log.d(tag, "Re-subscribing to topic \(baseUrl)/\(topic)")
        Messaging.messaging().subscribe(toTopic: firebaseTopicName) { error in
            if let error {
                Log.e(self.tag, "Firebase subscribe failed for \(firebaseTopicName)", error)
            } else {
                Log.d(self.tag, "Firebase subscribe succeeded for \(firebaseTopicName)")
            }
        }
    }
}
```

This is exactly the body currently inline in `didReceiveRegistrationToken`; that method's body becomes a single call to this new method. Firebase no-ops if already subscribed, so calling this repeatedly is safe — it only meaningfully retries topics that previously failed.

### 2. Call it from two additional places

- **`AppMain.swift`'s foreground hook** (`onReceive(...didBecomeActiveNotification...)`), alongside the existing `store.hardRefresh()` / `delegate.refreshNotificationSettings()` calls: add `delegate.subscribeToFirebaseTopics()`.
- **`AppDelegate`'s background `~poll` remote-notification handler** (`application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`): call `subscribeToFirebaseTopics()` once at the start of the handler, before polling subscriptions.

### 3. `willPresent` saves the incoming message to Core Data

Currently:

```swift
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
) {
    let userInfo = notification.request.content.userInfo
    Log.d(tag, "Notification received via userNotificationCenter(willPresent)", userInfo)
    completionHandler([[.banner, .sound]])
}
```

Add a Core Data save before calling the completion handler, using the same `Message.from(userInfo:)` parsing and `base_url` extraction already used a few lines below in `userNotificationCenter(didReceive:)`:

```swift
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
) {
    let userInfo = notification.request.content.userInfo
    Log.d(tag, "Notification received via userNotificationCenter(willPresent)", userInfo)
    if let message = Message.from(userInfo: userInfo), message.event == "message" {
        let baseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
        _ = Store.shared.save(notificationFromMessage: message, baseUrl: baseUrl, topic: message.topic)
    }
    completionHandler([[.banner, .sound]])
}
```

`Store.save(notificationFromMessage:baseUrl:topic:)` already exists and is exactly what the NSE itself calls (`NotificationService.swift`'s `handleMessage`) — it looks up the subscription by `baseUrl`/`topic` and funnels through `saveNotifications`, which already dedupes by message ID before inserting. Calling this unconditionally from `willPresent` is safe even when NSE also runs and saves the same message: whichever save happens second is a no-op against the existing ID.

### 4. Reduce Firebase log noise

`FirebaseConfiguration.shared.setLoggerLevel(.max)` → `.setLoggerLevel(.warning)` in `application(_:didFinishLaunchingWithOptions:)`.

## Out of scope

- The `DispatchGroup` completion-handler timing and idempotent-save-by-ID logic from PR #28 are not ported — both are already handled equivalently in this fork's current code (confirmed by reading `AppDelegate.swift`'s background-fetch handler and `Store.saveNotifications`).
- Persistent log file + Share Logs button, and the XCTest target, are separate, larger pieces of work (items #3 and #4 in the agreed ordering) — not part of this spec.

## Testing

No XCTest target exists yet in this project — verification is build checks plus manual checks:

- Build check after each change.
- Manual: with the app in the foreground, trigger a push delivery (e.g. `xcrun simctl push` on Simulator, where NSE is known not to run) and confirm the message now appears in the topic list, not just as a banner.
- Manual: confirm no duplicate notifications appear for a message delivered through both `willPresent` and NSE on a real device (where both paths can run).
- Manual: foreground the app and background-poll-trigger it; confirm `subscribeToFirebaseTopics` logs fire without errors in both cases.
