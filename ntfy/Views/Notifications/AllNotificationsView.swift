import SwiftUI
import UserNotifications

struct AllNotificationsView: View {
    private let tag = "AllNotificationsView"

    @EnvironmentObject private var store: Store
    @ObservedObject var notificationsModel: AllNotificationsObservable

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showClearAllAlert = false

    private var filteredNotifications: [Notification] {
        guard !debouncedSearchText.isEmpty else {
            return notificationsModel.notifications
        }
        return notificationsModel.notifications.filter {
            $0.formatMessage().localizedCaseInsensitiveContains(debouncedSearchText) ||
            ($0.formatTitle()?.localizedCaseInsensitiveContains(debouncedSearchText) ?? false)
        }
    }

    var body: some View {
        List {
            ForEach(filteredNotifications, id: \.self) { notification in
                NotificationRowView(
                    notification: notification,
                    onCopyMessage: {},
                    subscriptionLabel: notification.subscription?.displayName()
                )
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search notifications")
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedSearchText = searchText
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("All Notifications")
                    .font(.headline)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if notificationsModel.notifications.count > 0 {
                    Button("Clear all") {
                        showClearAllAlert = true
                    }
                }
            }
        }
        .overlay {
            if notificationsModel.notifications.isEmpty {
                emptyState
            }
        }
        .alert("Clear all notifications", isPresented: $showClearAllAlert) {
            Button("Permanently delete", role: .destructive) {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                store.deleteAllNotifications()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you really want to delete all of the notifications across every topic?")
        }
        .onAppear {
            cancelAllDeliveredNotifications()
        }
        .refreshable {
            await pollAllSubscriptions()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            "No notifications yet",
            systemImage: "bell.slash",
            description: Text("Notifications from all of your subscribed topics will show up here.")
        )
    }

    private func cancelAllDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    private func pollAllSubscriptions() async {
        let subscriptionManager = SubscriptionManager(store: store)
        await withTaskGroup(of: Void.self) { group in
            for subscription in store.getSubscriptions() ?? [] {
                group.addTask {
                    await subscriptionManager.poll(subscription)
                }
            }
        }
    }
}

#Preview {
    let store = Store.preview
    NavigationStack {
        AllNotificationsView(notificationsModel: AllNotificationsObservable())
    }
    .environment(\.managedObjectContext, store.context)
    .environmentObject(store)
    .environmentObject(AppIconManager())
}
