# Notification Delivery Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two live bugs in `AppDelegate.swift` — foreground-delivered messages never being saved to Core Data, and Firebase topic subscriptions never being retried after the initial token refresh — plus quiet down Firebase's log verbosity.

**Architecture:** All changes live in `ntfy/App/AppDelegate.swift` and `ntfy/App/AppMain.swift`. No new files, no data model changes. The fixes reuse existing `Store` methods (`save(notificationFromMessage:baseUrl:topic:)`) and existing parsing helpers (`Message.from(userInfo:)`) already used elsewhere in the same file.

**Tech Stack:** Swift, UIKit app delegate, Firebase Cloud Messaging, UserNotifications framework.

## Global Constraints

- This project has no XCTest target — every task's verification is a build check plus a manual check, not an automated test.
- Deployment target is iOS 16 project-wide; don't introduce anything newer without an existing `#available` pattern to follow.
- `willPresent`'s new Core Data save must be safe to call even when NSE also saves the same message — rely on `Store.saveNotifications`'s existing dedup-by-ID behavior (already in place; do not add a second dedup check).
- `subscribeToFirebaseTopics()` must be safe to call repeatedly (foreground, background poll, and token refresh can all trigger it in the same app lifetime) — Firebase itself no-ops on an already-subscribed topic, so no additional guard is needed.

---

### Task 1: Extract `subscribeToFirebaseTopics()` and quiet Firebase logging

**Files:**
- Modify: `ntfy/App/AppDelegate.swift:17-33` (logger level), `ntfy/App/AppDelegate.swift:240-273` (extract method)

**Interfaces:**
- Produces: `AppDelegate.subscribeToFirebaseTopics()` — a new internal (non-private) instance method on `AppDelegate`, no parameters, no return value. Tasks 2 and 3 do not call this method (it's only called from the token-refresh handler in this task); it's introduced here so Task 2 can add two more call sites to it.

- [ ] **Step 1: Reduce Firebase logger verbosity**

In `ntfy/App/AppDelegate.swift`, change line 21 from:

```swift
        FirebaseConfiguration.shared.setLoggerLevel(.max)
```

to:

```swift
        FirebaseConfiguration.shared.setLoggerLevel(.warning)
```

- [ ] **Step 2: Extract the re-subscription logic into a reusable method**

In `ntfy/App/AppDelegate.swift`, find the `MessagingDelegate` extension at the bottom of the file (currently lines 240-273):

```swift
extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let fcmToken = fcmToken, !fcmToken.isEmpty {
            Log.d(tag, "Firebase token received: \(fcmToken.prefix(12))...")
        } else {
            Log.w(tag, "Firebase token missing")
        }
        
        // Subscribe to ~poll topic
        Messaging.messaging().subscribe(toTopic: pollTopic) { error in
            if let error {
                Log.e(self.tag, "Firebase subscribe failed for \(self.pollTopic)", error)
            } else {
                Log.d(self.tag, "Firebase subscribe succeeded for \(self.pollTopic)")
            }
        }
        
        // Re-subscribe to Firebase for all topics
        let store = Store.shared
        store.getSubscriptions()?.forEach{ subscription in
            if let baseUrl = subscription.baseUrl, let topic = subscription.topic {
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
    }
}
```

Replace it with:

```swift
extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let fcmToken = fcmToken, !fcmToken.isEmpty {
            Log.d(tag, "Firebase token received: \(fcmToken.prefix(12))...")
        } else {
            Log.w(tag, "Firebase token missing")
        }

        subscribeToFirebaseTopics()
    }
}

extension AppDelegate {
    /// (Re-)subscribes to the "~poll" topic and every current subscription's Firebase topic.
    /// Safe to call repeatedly: Firebase no-ops on an already-subscribed topic, so this only
    /// meaningfully retries topics that previously failed to subscribe. Called on token
    /// refresh, on every app foreground, and on every background "~poll" trigger, to recover
    /// from silent subscription failures (network blip, token rotation) without waiting for
    /// the token itself to change again.
    func subscribeToFirebaseTopics() {
        // Subscribe to ~poll topic
        Messaging.messaging().subscribe(toTopic: pollTopic) { error in
            if let error {
                Log.e(self.tag, "Firebase subscribe failed for \(self.pollTopic)", error)
            } else {
                Log.d(self.tag, "Firebase subscribe succeeded for \(self.pollTopic)")
            }
        }

        // Re-subscribe to Firebase for all topics
        let store = Store.shared
        store.getSubscriptions()?.forEach { subscription in
            if let baseUrl = subscription.baseUrl, let topic = subscription.topic {
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
    }
}
```

Note this is a pure extraction — the body of `subscribeToFirebaseTopics()` is byte-for-byte the same logic that was inline in `didReceiveRegistrationToken`, just renamed into its own method and no longer `private` (dropped implicitly — Swift's default access level is `internal`, which is what's needed here since `AppMain.swift`, a different file in the same module, will call it in Task 2).

- [ ] **Step 3: Build to verify it compiles**

Run: `cd /Users/hibikipr/Developer/ntfy-ios && xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`

Expected: exit status 0, no output.

- [ ] **Step 4: Manual check**

This step only restructures existing, already-working logic — there is no new observable behavior yet (Tasks 2 and 3 add the new call sites and the Core Data save). Skip manual verification here; Task 2's manual check exercises this method's new call sites, which is the earliest point new behavior exists to observe.

- [ ] **Step 5: Commit**

```bash
cd /Users/hibikipr/Developer/ntfy-ios
git add ntfy/App/AppDelegate.swift
git commit -m "Extract subscribeToFirebaseTopics() and reduce Firebase log verbosity"
```

---

### Task 2: Retry Firebase re-subscription on foreground and background poll

**Files:**
- Modify: `ntfy/App/AppMain.swift:18-33`
- Modify: `ntfy/App/AppDelegate.swift` (the background `~poll` handler, `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`, currently lines 95-140 — line numbers will have shifted slightly after Task 1's edit; locate by the method's doc comment `/// Executed when a background notification arrives on the "~poll" topic.`)

**Interfaces:**
- Consumes: `AppDelegate.subscribeToFirebaseTopics()` (Task 1, no parameters, no return value)

- [ ] **Step 1: Call it from the foreground hook**

In `ntfy/App/AppMain.swift`, the `onReceive` closure currently reads:

```swift
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Use this hook instead of applicationDidBecomeActive, see https://stackoverflow.com/a/68888509/1440785
                    // That post also explains how to start SwiftUI from AppDelegate if that's ever needed.
                    
                    Log.d(tag, "App became active, refreshing objects")
                    store.hardRefresh()
                    delegate.refreshNotificationSettings()
                }
```

Add one line after `delegate.refreshNotificationSettings()`:

```swift
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Use this hook instead of applicationDidBecomeActive, see https://stackoverflow.com/a/68888509/1440785
                    // That post also explains how to start SwiftUI from AppDelegate if that's ever needed.
                    
                    Log.d(tag, "App became active, refreshing objects")
                    store.hardRefresh()
                    delegate.refreshNotificationSettings()
                    delegate.subscribeToFirebaseTopics()
                }
```

- [ ] **Step 2: Call it from the background "~poll" handler**

In `ntfy/App/AppDelegate.swift`, find the method with this doc comment:

```swift
    /// Executed when a background notification arrives on the "~poll" topic. This is used to trigger polling of local topics.
    /// See https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/pushing_background_updates_to_your_app
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Log.d(tag, "Background notification received", userInfo)
        
        // Exit out early if this message is not expected
        let topic = userInfo["topic"] as? String ?? ""
        if topic != pollTopic {
            completionHandler(.noData)
            return
        }

        // Poll and show new messages as notifications
        let store = Store.shared
```

Add a call to `subscribeToFirebaseTopics()` right after the early-exit guard, before polling starts:

```swift
    /// Executed when a background notification arrives on the "~poll" topic. This is used to trigger polling of local topics.
    /// See https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/pushing_background_updates_to_your_app
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Log.d(tag, "Background notification received", userInfo)
        
        // Exit out early if this message is not expected
        let topic = userInfo["topic"] as? String ?? ""
        if topic != pollTopic {
            completionHandler(.noData)
            return
        }

        // Retry any previously-failed Firebase subscriptions while we're already awake (#1305)
        subscribeToFirebaseTopics()

        // Poll and show new messages as notifications
        let store = Store.shared
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd /Users/hibikipr/Developer/ntfy-ios && xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`

Expected: exit status 0, no output.

- [ ] **Step 4: Manual check**

Install and launch the app on a simulator or device with at least one existing subscription. Background it, then foreground it again (or just relaunch), and check the device logs for the new subscribe-attempt log lines:

```bash
xcrun simctl spawn <device> log stream --predicate 'process == "ntfy"' --level debug
```

Expected: `Firebase subscribe succeeded for ~poll` and one `Re-subscribing to topic ...` / `Firebase subscribe succeeded for ...` pair per existing subscription, logged shortly after the app becomes active — not just once at first launch.

- [ ] **Step 5: Commit**

```bash
cd /Users/hibikipr/Developer/ntfy-ios
git add ntfy/App/AppMain.swift ntfy/App/AppDelegate.swift
git commit -m "Retry Firebase topic subscription on foreground and background poll"
```

---

### Task 3: Save foreground-delivered messages to Core Data

**Files:**
- Modify: `ntfy/App/AppDelegate.swift` (the `UNUserNotificationCenterDelegate` extension, `userNotificationCenter(willPresent:withCompletionHandler:)`)

**Interfaces:**
- Consumes: `Store.save(notificationFromMessage message: Message, baseUrl: String, topic: String) -> Bool` (already exists in `ntfy/Persistence/Store.swift` — the same method the notification-service-extension's `handleMessage` calls). `Message.from(userInfo: [AnyHashable: Any]) -> Message?` (already exists in `ntfy/Persistence/Notification.swift`, already used a few lines below in this same file's `didReceive` handler).

- [ ] **Step 1: Save the message before presenting the banner**

In `ntfy/App/AppDelegate.swift`, find:

```swift
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Executed when the app is in the foreground. Nothing has to be done here, except call the completionHandler.
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

Replace with:

```swift
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Executed when the app is in the foreground. The notification-service-extension (NSE) is what
    /// normally saves an incoming message to Core Data, but NSE does not run on the Simulator (a
    /// documented Apple limitation) and can be skipped by the system in some foreground scenarios on
    /// real devices too. Save here as a fallback so the message always ends up in the topic list, not
    /// just as a transient banner. Safe to call even when NSE also saves the same message — Store's
    /// save path already dedupes by message ID before inserting.
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

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/hibikipr/Developer/ntfy-ios && xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`

Expected: exit status 0, no output.

- [ ] **Step 3: Manual check**

With the app foregrounded on a simulator (where NSE is guaranteed not to run) and at least one existing subscription, first confirm the actual installed bundle ID — this branch's local signing override (see `ntfy.xcodeproj/project.pbxproj`'s uncommitted `PRODUCT_BUNDLE_IDENTIFIER`) may not be `io.heckel.ntfy`:

```bash
grep -m1 "PRODUCT_BUNDLE_IDENTIFIER" /Users/hibikipr/Developer/ntfy-ios/ntfy.xcodeproj/project.pbxproj
```

Use that value (not necessarily `io.heckel.ntfy`) as `<bundle-id>` below:

```bash
xcrun simctl push <device> <bundle-id> - <<'EOF'
{
  "aps": { "alert": { "title": "Test", "body": "Delivery fix check" }, "mutable-content": 1 },
  "id": "willpresent-test-1",
  "time": 1784980000,
  "event": "message",
  "topic": "<an existing subscribed topic>",
  "message": "Delivery fix check",
  "base_url": "https://ntfy.sh"
}
EOF
```

(Adjust `topic` and `base_url` to match a real existing subscription so `Store.getSubscription` can find it.)

Expected: the banner appears as before, **and** the message now shows up in that topic's notification list and in "All Notifications" without needing a manual pull-to-refresh — confirming the Core Data save happened via `willPresent`, not just via a later poll.

- [ ] **Step 4: Commit**

```bash
cd /Users/hibikipr/Developer/ntfy-ios
git add ntfy/App/AppDelegate.swift
git commit -m "Save foreground-delivered messages to Core Data in willPresent"
```

---

## Self-Review Notes

- **Spec coverage:** logger level (Task 1), extracted re-subscription method (Task 1), foreground + background-poll retry call sites (Task 2), `willPresent` Core Data save (Task 3) — all four spec items covered.
- **Type consistency:** `subscribeToFirebaseTopics()` (no params, no return) is defined in Task 1 and called identically in Task 2's two new call sites. `Store.save(notificationFromMessage:baseUrl:topic:)`'s existing signature (`Message`, `String`, `String` → `Bool`) is used correctly in Task 3, matching its declaration in `Store.swift` and its existing usage in `NotificationService.swift`.
- **No test target:** every task substitutes a build check plus a concrete manual verification for the automated test cycle this skill normally prescribes, per the spec's stated project constraint.
