# Custom display names for subscriptions

## Context

Upstream [binwiederhier/ntfy-ios#50](https://github.com/binwiederhier/ntfy-ios/pull/50) adds a `customDisplayName` field so a subscription can show a friendlier label than its raw topic name (e.g. "Printer alerts" instead of `3dprinter-xk4j9`). It surfaces this via a "Rename" item in the topic's context menu, opening a dedicated Save/Cancel sheet.

This fork already has `Subscription.displayName()` (`ntfy/Persistence/Subscription.swift:8-10`) — it exists today but returns only `topicShortUrl(...)` and is never actually called anywhere; every row currently renders `subscription.topicName()` (the raw topic string) directly. It also already has an established "tap the avatar to customize this topic" sheet (`TopicIconEditorView.swift`, from the emoji-avatar feature built earlier this session) with a live-save-on-keystroke emoji field. This spec adapts PR #50's idea into that existing sheet rather than adding a second, separate customization entry point.

## Design

### 1. Data model

Add an optional `customDisplayName` attribute to the `Subscription` entity in `ntfy/Persistence/ntfy.xcdatamodeld/Model.xcdatamodel/contents`, alongside the existing `icon` attribute:

```xml
<attribute name="customDisplayName" optional="YES" attributeType="String" maxValueString="64"/>
```

Optional + `shouldMigrateStoreAutomatically`/`shouldInferMappingModelAutomatically` (already `true` in `Store.swift`) makes this a lightweight migration, same as `icon` was.

### 2. `Subscription.displayName()` becomes real

```swift
// ntfy/Persistence/Subscription.swift
func displayName() -> String {
    if let customDisplayName, !customDisplayName.isEmpty {
        return customDisplayName
    }
    return topicShortUrl(baseUrl: baseUrl ?? "?", topic: topic ?? "?")
}
```

(Currently just `return topicShortUrl(...)` unconditionally — the custom-name branch is new.)

### 3. `Store.saveDisplayName(for:name:)`

Mirrors `saveIcon(for:icon:)`'s shape (`Store.swift:125-130`), but trims whitespace and defensively caps at 64 characters in Swift rather than relying solely on the Core Data model's `maxValueString` constraint (which would otherwise fail the whole `context.save()` silently under `try?` if exceeded):

```swift
func saveDisplayName(for subscription: Subscription, name: String?) {
    context.performAndWait {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        subscription.customDisplayName = trimmed.isEmpty ? nil : String(trimmed.prefix(64))
        try? context.save()
    }
}
```

### 4. Editor sheet: rename `TopicIconEditorView` → `TopicEditorView`, add a Display Name section

The type now edits more than the icon, so it's renamed for honesty (mechanical rename, no behavior change to the existing emoji field). File `TopicIconEditorView.swift` → `TopicEditorView.swift`; struct `TopicIconEditorView` → `TopicEditorView`; the row's `@State private var showIconEditor` (`SubscriptionListView.swift:161`) → `showEditor`, and its `.sheet(isPresented:)` call updated to match.

The current sheet body is a plain `VStack(spacing: 24)` (not a `Form`/`List`), so the new section follows that same style — a `VStack`, not a `Section` — inserted after the existing emoji `TextField`/caption `VStack` and before the `Spacer()`/Remove button:

```swift
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
```

New `@State private var displayNameText: String`, seeded in `init` from `subscription.customDisplayName ?? ""` (parallel to how `iconText` is seeded from `subscription.icon ?? ""`).

**Save/Cancel behavior differs per field**, per the approved design: the emoji field keeps its existing live-save-on-keystroke (`onChange(of: iconText) { ... store.saveIcon(...) }`, unchanged). The name field is buffered in `displayNameText` and only committed when the sheet's toolbar "Save" button is tapped. The toolbar changes from today's single trailing "Done" (`TopicIconEditorView.swift:55-61`) to:

```swift
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
```

"Cancel" discards only the buffered name edit — any emoji change made in the same sheet visit was already committed live and is *not* rolled back by Cancel, matching how the emoji field already behaves today (there is no "cancel" for it currently either). This asymmetry is intentional per the approved design (emoji stays instant, name is deliberate), not an oversight.

### 5. Wire `displayName()` into the three places that currently call `topicName()` for a subscription's display label

- `SubscriptionItemRowView`'s title (`SubscriptionListView.swift:190`): `Text(subscription.topicName())` → `Text(subscription.displayName())`.
- `NotificationListView`'s nav-bar principal title (`NotificationListView.swift:61`): `Text(subscription.topicName())` → `Text(subscription.displayName())`.
- `AllNotificationsView`'s per-row subscription label (`AllNotificationsView.swift:29`): `subscriptionLabel: notification.subscription?.topicName()` → `subscriptionLabel: notification.subscription?.displayName()`.

`topicName()` itself (`Subscription.swift:12-14`) is unchanged and keeps its own remaining call sites — the two curl-example strings in `NotificationListView.swift:190,200` intentionally keep showing the *real* topic name (`ntfy.sh/<topic>`), since that's what a `curl` command actually needs, not a friendly display label. `TopicIconEditorView`'s `TopicAvatarView(name: subscription.topicName(), ...)` call (used only to derive the avatar's fallback-letter, not shown as text) also stays on `topicName()` — the letter avatar should reflect the real topic, not an arbitrary custom name.

## Out of scope

- No display-name field in `SubscriptionAddView` (the "add subscription" flow) — renaming happens post-creation via the editor sheet, matching upstream's approach.
- No length/character-set validation beyond the 64-char cap (matches upstream; topic names already have their own stricter regex-validated format, display names are free text).
- No syncing/sharing of display names across devices beyond whatever Core Data's existing `syncable="YES"` already provides for every other attribute.

## Testing

No XCTest target exists in this project — verification is build checks plus manual checks:

- Build check after each change.
- Manual: rename a topic via the editor sheet's Save button; confirm the new name appears in the topic list row, the notification list's nav-bar title, and the All Notifications view's per-row label.
- Manual: open the editor, type a new name, tap Cancel; confirm the name reverts to what it was (not saved).
- Manual: clear the name field to empty and Save; confirm the row falls back to the topic's short URL (matching `displayName()`'s existing fallback behavior).
- Manual: confirm editing the emoji in the same sheet visit still live-saves as before, independent of the name field's Save/Cancel.
