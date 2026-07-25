# Custom display names for subscriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A subscription can be given a custom display name (shown in place of the raw topic name across the app), editable from the same sheet that already edits the topic's emoji avatar.

**Architecture:** A new optional `customDisplayName` Core Data attribute, a `Store.saveDisplayName(for:name:)` method mirroring the existing `saveIcon(for:icon:)`, `Subscription.displayName()` (already defined, currently dead code) made custom-name-aware, and the existing `TopicIconEditorView` renamed to `TopicEditorView` with a new buffered (Save/Cancel) name field alongside its existing live-save emoji field.

**Tech Stack:** Swift, SwiftUI, Core Data.

## Global Constraints

- No XCTest target exists in this project — verification is build checks plus manual checks.
- The emoji field's existing live-save-on-keystroke behavior is unchanged. Only the new display-name field is buffered behind Save/Cancel.
- `project.pbxproj` is manually maintained — the file rename in Task 2 updates the existing `PBXFileReference`'s `path` and both `/* TopicIconEditorView.swift */`-style comment names to `TopicEditorView.swift`; it does **not** need new IDs (same file reference, same build-file entry, just renamed).
- `topicName()` (the raw topic string) keeps all of its current call sites unchanged — the curl-example strings in `NotificationListView.swift` and the avatar's fallback-letter source in the editor sheet must keep showing the real topic name, not the custom display name.

---

### Task 1: Data model + `Store.saveDisplayName` + real `Subscription.displayName()`

**Files:**
- Modify: `ntfy/Persistence/ntfy.xcdatamodeld/Model.xcdatamodel/contents`
- Modify: `ntfy/Persistence/Subscription.swift`
- Modify: `ntfy/Persistence/Store.swift`

**Interfaces:**
- Produces: `Subscription.displayName() -> String` (existing signature, now custom-name-aware); `Store.saveDisplayName(for subscription: Subscription, name: String?)` — both consumed by Task 2's editor sheet. `Store.saveDisplayName` is also indirectly relied on by Task 3's manual verification (there is no other way to set a custom name).

- [ ] **Step 1: Add the `customDisplayName` attribute to the Core Data model**

Find, in `ntfy/Persistence/ntfy.xcdatamodeld/Model.xcdatamodel/contents`:

```xml
    <entity name="Subscription" representedClassName="Subscription" syncable="YES" codeGenerationType="class">
        <attribute name="baseUrl" attributeType="String"/>
        <attribute name="icon" optional="YES" attributeType="String"/>
        <attribute name="lastNotificationId" optional="YES" attributeType="String"/>
        <attribute name="topic" attributeType="String" minValueString="1" maxValueString="64" regularExpressionString="^[-_A-Za-z0-9]{1,64}$"/>
```

Replace with:

```xml
    <entity name="Subscription" representedClassName="Subscription" syncable="YES" codeGenerationType="class">
        <attribute name="baseUrl" attributeType="String"/>
        <attribute name="customDisplayName" optional="YES" attributeType="String" maxValueString="64"/>
        <attribute name="icon" optional="YES" attributeType="String"/>
        <attribute name="lastNotificationId" optional="YES" attributeType="String"/>
        <attribute name="topic" attributeType="String" minValueString="1" maxValueString="64" regularExpressionString="^[-_A-Za-z0-9]{1,64}$"/>
```

This is a lightweight, backwards-compatible migration — `Store.swift` already has `shouldMigrateStoreAutomatically = true` / `shouldInferMappingModelAutomatically = true` (same as when `icon` was added earlier).

- [ ] **Step 2: Make `Subscription.displayName()` custom-name-aware**

Find, in `ntfy/Persistence/Subscription.swift`:

```swift
    func displayName() -> String {
        return topicShortUrl(baseUrl: baseUrl ?? "?", topic: topic ?? "?")
    }
```

Replace with:

```swift
    func displayName() -> String {
        if let customDisplayName, !customDisplayName.isEmpty {
            return customDisplayName
        }
        return topicShortUrl(baseUrl: baseUrl ?? "?", topic: topic ?? "?")
    }
```

- [ ] **Step 3: Add `Store.saveDisplayName(for:name:)`**

In `ntfy/Persistence/Store.swift`, find `saveIcon(for:icon:)`:

```swift
    func saveIcon(for subscription: Subscription, icon: String?) {
        context.performAndWait {
            subscription.icon = (icon?.isEmpty ?? true) ? nil : icon
            try? context.save()
        }
    }
```

Add a new method directly after it:

```swift
    func saveDisplayName(for subscription: Subscription, name: String?) {
        context.performAndWait {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            subscription.customDisplayName = trimmed.isEmpty ? nil : String(trimmed.prefix(64))
            try? context.save()
        }
    }
```

(The 64-character cap is applied defensively in Swift rather than relying solely on the Core Data model's `maxValueString` constraint, since exceeding that constraint would otherwise fail the whole `context.save()` silently under `try?`.)

- [ ] **Step 4: Build check**

Run: `xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`
Expected: exit 0, no errors.

- [ ] **Step 5: Commit**

```bash
git add ntfy/Persistence/ntfy.xcdatamodeld/Model.xcdatamodel/contents ntfy/Persistence/Subscription.swift ntfy/Persistence/Store.swift
git commit -m "Add customDisplayName to Subscription model and Store"
```

---

### Task 2: Rename `TopicIconEditorView` → `TopicEditorView`, add a buffered Display Name field

**Files:**
- Rename: `ntfy/Views/Subscriptions/TopicIconEditorView.swift` → `ntfy/Views/Subscriptions/TopicEditorView.swift`
- Modify: `ntfy/Views/Subscriptions/SubscriptionListView.swift`
- Modify: `ntfy.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Store.saveDisplayName(for:name:)`, `Subscription.displayName()` (Task 1).
- Produces: `TopicEditorView` (renamed from `TopicIconEditorView`) — consumed by `SubscriptionListView.swift` in this same task.

- [ ] **Step 1: Rename the file**

```bash
git mv ntfy/Views/Subscriptions/TopicIconEditorView.swift ntfy/Views/Subscriptions/TopicEditorView.swift
```

- [ ] **Step 2: Replace the renamed file's full contents**

Current content (after the rename, still the old code):

```swift
import SwiftUI

struct TopicIconEditorView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var subscription: Subscription
    @State private var iconText: String

    init(subscription: Subscription) {
        self.subscription = subscription
        _iconText = State(initialValue: subscription.icon ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TopicAvatarView(name: subscription.topicName(), emoji: iconText.isEmpty ? nil : iconText)
                    .scaleEffect(2)
                    .padding(.top, 24)

                VStack(spacing: 8) {
                    TextField("Emoji", text: $iconText)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 32))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: iconText) { newValue in
                            if let last = newValue.last {
                                iconText = String(last)
                            }
                            store.saveIcon(for: subscription, icon: iconText)
                        }

                    Text("Tap the field, then tap the globe/emoji key on the keyboard to pick one.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                if !iconText.isEmpty {
                    Button(role: .destructive) {
                        iconText = ""
                        store.saveIcon(for: subscription, icon: nil)
                    } label: {
                        Text("Remove")
                    }
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle(subscription.topicName())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TopicIconEditorView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview
        let subscription = store.makeSubscription(store.context, "stats", Store.sampleMessages["stats"]!)
        TopicIconEditorView(subscription: subscription)
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
    }
}
```

Replace the entire file with:

```swift
import SwiftUI

struct TopicEditorView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var subscription: Subscription
    @State private var iconText: String
    @State private var displayNameText: String

    init(subscription: Subscription) {
        self.subscription = subscription
        _iconText = State(initialValue: subscription.icon ?? "")
        _displayNameText = State(initialValue: subscription.customDisplayName ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TopicAvatarView(name: subscription.topicName(), emoji: iconText.isEmpty ? nil : iconText)
                    .scaleEffect(2)
                    .padding(.top, 24)

                VStack(spacing: 8) {
                    TextField("Emoji", text: $iconText)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 32))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: iconText) { newValue in
                            if let last = newValue.last {
                                iconText = String(last)
                            }
                            store.saveIcon(for: subscription, icon: iconText)
                        }

                    Text("Tap the field, then tap the globe/emoji key on the keyboard to pick one.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Divider()
                    .padding(.horizontal, 32)

                VStack(spacing: 8) {
                    Text("Display Name")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    TextField(subscription.displayName(), text: $displayNameText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .frame(width: 220)
                    Text("Leave empty to show the default topic name.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                if !iconText.isEmpty {
                    Button(role: .destructive) {
                        iconText = ""
                        store.saveIcon(for: subscription, icon: nil)
                    } label: {
                        Text("Remove")
                    }
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle(subscription.topicName())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.saveDisplayName(for: subscription, name: displayNameText)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TopicEditorView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview
        let subscription = store.makeSubscription(store.context, "stats", Store.sampleMessages["stats"]!)
        TopicEditorView(subscription: subscription)
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
    }
}
```

Note: "Cancel" only discards the buffered `displayNameText` edit. Any emoji change made during the same sheet visit was already committed live via `onChange` (unchanged behavior) and is not rolled back by Cancel — this matches how the emoji field already behaved before this task (there was no "cancel" for it either).

- [ ] **Step 3: Update `SubscriptionListView.swift`'s call site**

Find:

```swift
struct SubscriptionItemRowView: View {
    @ObservedObject var subscription: Subscription
    @StateObject private var notificationsModel: NotificationsObservable
    @State private var showIconEditor = false
```

Replace with:

```swift
struct SubscriptionItemRowView: View {
    @ObservedObject var subscription: Subscription
    @StateObject private var notificationsModel: NotificationsObservable
    @State private var showEditor = false
```

Find:

```swift
            Button {
                showIconEditor = true
            } label: {
                TopicAvatarView(name: subscription.topicName(), emoji: subscription.icon)
            }
```

Replace with:

```swift
            Button {
                showEditor = true
            } label: {
                TopicAvatarView(name: subscription.topicName(), emoji: subscription.icon)
            }
```

Find:

```swift
        .sheet(isPresented: $showIconEditor) {
            TopicIconEditorView(subscription: subscription)
        }
```

Replace with:

```swift
        .sheet(isPresented: $showEditor) {
            TopicEditorView(subscription: subscription)
        }
```

- [ ] **Step 4: Update `project.pbxproj`**

Four occurrences of `TopicIconEditorView.swift` become `TopicEditorView.swift` — the file reference's `path`, and every `/* TopicIconEditorView.swift */`-style comment name (both bare and the `in Sources` variant). The IDs (`258B5053A8C14C1477993609`, `CBE8DE340E147766BAA25874`) are unchanged — this is a rename of an existing reference, not a new file.

Find:

```
		258B5053A8C14C1477993609 /* TopicIconEditorView.swift in Sources */ = {isa = PBXBuildFile; fileRef = CBE8DE340E147766BAA25874 /* TopicIconEditorView.swift */; };
```

Replace with:

```
		258B5053A8C14C1477993609 /* TopicEditorView.swift in Sources */ = {isa = PBXBuildFile; fileRef = CBE8DE340E147766BAA25874 /* TopicEditorView.swift */; };
```

Find:

```
		CBE8DE340E147766BAA25874 /* TopicIconEditorView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TopicIconEditorView.swift; sourceTree = "<group>"; };
```

Replace with:

```
		CBE8DE340E147766BAA25874 /* TopicEditorView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TopicEditorView.swift; sourceTree = "<group>"; };
```

Find:

```
				CBE8DE340E147766BAA25874 /* TopicIconEditorView.swift */,
```

Replace with:

```
				CBE8DE340E147766BAA25874 /* TopicEditorView.swift */,
```

Find:

```
				258B5053A8C14C1477993609 /* TopicIconEditorView.swift in Sources */,
```

Replace with:

```
				258B5053A8C14C1477993609 /* TopicEditorView.swift in Sources */,
```

- [ ] **Step 5: Build check**

Run: `xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`
Expected: exit 0, no errors.

- [ ] **Step 6: Manual check**

Launch the app, tap a topic's avatar in the topic list to open the editor. Confirm: the new "Display Name" field appears below the emoji field with a divider between them, its placeholder shows the topic's current `displayName()` (initially the short URL, since no custom name is set yet), and the toolbar now shows "Cancel" (leading) and "Save" (trailing) instead of a single "Done".

Type a name and tap **Save**; confirm the sheet dismisses. Re-open the editor for the same topic; confirm the field is now pre-filled with the saved name (via `displayNameText`'s `init` seeding from `subscription.customDisplayName`).

Type a *different* name and tap **Cancel**; confirm the sheet dismisses without changing anything. Re-open the editor; confirm the field still shows the name saved in the previous step (the Cancelled edit was discarded), and separately confirm any emoji typed during this same visit was still saved (matching its existing live-save behavior, unaffected by Cancel).

- [ ] **Step 7: Commit**

```bash
git add ntfy/Views/Subscriptions/TopicEditorView.swift ntfy/Views/Subscriptions/SubscriptionListView.swift ntfy.xcodeproj/project.pbxproj
git commit -m "Rename TopicIconEditorView to TopicEditorView, add buffered Display Name field"
```

---

### Task 3: Wire `displayName()` into the three subscription-label call sites

**Files:**
- Modify: `ntfy/Views/Subscriptions/SubscriptionListView.swift`
- Modify: `ntfy/Views/Notifications/NotificationListView.swift`
- Modify: `ntfy/Views/Notifications/AllNotificationsView.swift`

**Interfaces:**
- Consumes: `Subscription.displayName()` (Task 1).

- [ ] **Step 1: `SubscriptionItemRowView`'s title**

Find, in `ntfy/Views/Subscriptions/SubscriptionListView.swift`:

```swift
                    VStack(alignment: .leading, spacing: 0) {
                        Text(subscription.topicName())
                            .font(.headline)
                            .lineLimit(1)
```

Replace with:

```swift
                    VStack(alignment: .leading, spacing: 0) {
                        Text(subscription.displayName())
                            .font(.headline)
                            .lineLimit(1)
```

- [ ] **Step 2: `NotificationListView`'s nav-bar principal title**

Find, in `ntfy/Views/Notifications/NotificationListView.swift`:

```swift
            ToolbarItem(placement: .principal) {
                Text(subscription.topicName())
                    .font(.headline)
                    .lineLimit(1)
            }
```

Replace with:

```swift
            ToolbarItem(placement: .principal) {
                Text(subscription.displayName())
                    .font(.headline)
                    .lineLimit(1)
            }
```

(The two curl-example strings later in this same file, at `ntfy.sh/\(subscription.topicName())`, are unchanged — they need the real topic name, not the display name.)

- [ ] **Step 3: `AllNotificationsView`'s per-row subscription label**

Find, in `ntfy/Views/Notifications/AllNotificationsView.swift`:

```swift
                NotificationRowView(
                    notification: notification,
                    onCopyMessage: {},
                    subscriptionLabel: notification.subscription?.topicName()
                )
```

Replace with:

```swift
                NotificationRowView(
                    notification: notification,
                    onCopyMessage: {},
                    subscriptionLabel: notification.subscription?.displayName()
                )
```

- [ ] **Step 4: Build check**

Run: `xcodebuild build -scheme ntfy -destination 'platform=iOS Simulator,name=<available iPhone>' -quiet`
Expected: exit 0, no errors.

- [ ] **Step 5: Manual check**

Using the custom name saved in Task 2's manual check: confirm it now appears in (a) the topic list row's title, (b) the notification list's nav-bar title when you open that topic, and (c) the All Notifications view's per-row subscription-label badge for notifications belonging to that topic.

Then open the editor again, clear the Display Name field to empty, and Save. Confirm all three locations fall back to the topic's short URL (`displayName()`'s existing fallback), not the raw topic name.

- [ ] **Step 6: Commit**

```bash
git add ntfy/Views/Subscriptions/SubscriptionListView.swift ntfy/Views/Notifications/NotificationListView.swift ntfy/Views/Notifications/AllNotificationsView.swift
git commit -m "Show custom display names in topic list, notification list, and All Notifications"
```

---

## Self-Review Notes

- **Spec coverage:** data model + `displayName()` + `Store.saveDisplayName` (Task 1), editor sheet rename + buffered name field + Save/Cancel toolbar (Task 2), wiring into the three display call sites (Task 3) — all five spec sections covered. The spec's "Out of scope" items (no name field in `SubscriptionAddView`, no extra validation beyond the 64-char cap, no custom sync logic) are correctly not implemented anywhere in this plan.
- **Type consistency:** `Store.saveDisplayName(for subscription: Subscription, name: String?)` (Task 1) is called with matching argument labels and types in Task 2's `TopicEditorView`. `Subscription.displayName() -> String` (Task 1) is called identically (no arguments, non-optional `String` return) in all three Task 3 call sites.
- **`topicName()` call sites not touched:** confirmed the two curl-example strings in `NotificationListView.swift` and the `TopicAvatarView(name: subscription.topicName(), ...)` calls in both `SubscriptionListView.swift` and `TopicEditorView.swift` are correctly left alone — they need the real topic name (for the curl command, and for the avatar's fallback-letter derivation), not the display name.
- **No test target:** every task substitutes a build check plus a concrete manual verification for the automated test cycle this skill normally prescribes, per the project-wide constraint already established in every prior plan this session.
