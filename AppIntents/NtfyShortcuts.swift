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
