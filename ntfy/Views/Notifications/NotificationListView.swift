import SwiftUI
import UniformTypeIdentifiers
import UIKit

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

struct NotificationListView: View {
    private let tag = "NotificationListView"
    
    @Environment(AppDelegate.self) private var delegate
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var iconManager: AppIconManager

    @ObservedObject var subscription: Subscription
    @StateObject private var notificationsModel: NotificationsObservable

    @State private var editMode = EditMode.inactive
    @State private var selection = Set<Notification>()

    @State private var pendingAlert: PendingAlert?
    @State private var showCopiedConfirmation = false
    @State private var searchText = ""

    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }

    init(subscription: Subscription) {
        self.subscription = subscription
        _notificationsModel = StateObject(wrappedValue: NotificationsObservable(subscriptionID: subscription.objectID))
    }

    var body: some View {
        notificationList
            .refreshable {
                await subscriptionManager.poll(subscription)
            }
    }
    
    private var notificationList: some View {
        Group {
            if editMode == .active {
                List(selection: $selection) {
                    notificationRows
                }
            } else {
                List {
                    notificationRows
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
        .searchable(text: $searchText, prompt: "Search notifications")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, self.$editMode)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(subscription.displayName())
                    .font(.headline)
                    .lineLimit(1)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if (self.editMode == .active) {
                    editButton
                } else {
                    Menu {
                        if notificationsModel.notifications.count > 0 {
                            editButton
                        }
                        Button("Send test notification") {
                            self.sendTestNotification()
                        }
                        if notificationsModel.notifications.count > 0 {
                            Button("Clear all notifications") {
                                self.pendingAlert = .clear
                            }
                        }
                        Button("Unsubscribe") {
                            self.pendingAlert = .unsubscribe
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if (self.editMode == .active) {
                    Button(action: {
                        self.pendingAlert = .selected
                    }) {
                        Text("Delete")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .alert(pendingAlert?.title ?? "", item: $pendingAlert) { alert in
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
        .overlay {
            if notificationsModel.notifications.isEmpty {
                emptyState
            }
        }
        .overlay(Group {
            if showCopiedConfirmation {
                Label("Copied to Clipboard", systemImage: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(iconManager.current.accentColor), in: .capsule)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        })
        .onAppear {
            cancelSubscriptionNotifications()
        }
        .onDisappear {
            if delegate.selectedBaseUrl == subscription.urlString() {
                delegate.selectedBaseUrl = nil
            }
        }
    }
    
    @ViewBuilder
    private var notificationRows: some View {
        ForEach(filteredNotifications, id: \.self) { notification in
            NotificationRowView(
                notification: notification,
                onCopyMessage: showCopyConfirmation
            )
        }
    }

    private var filteredNotifications: [Notification] {
        guard !searchText.isEmpty else {
            return notificationsModel.notifications
        }
        return notificationsModel.notifications.filter {
            $0.formatMessage().localizedCaseInsensitiveContains(searchText) ||
            ($0.formatTitle()?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No notifications yet", systemImage: "bell.slash")
        } description: {
            VStack(spacing: 12) {
                Text("To send notifications to this topic, simply PUT or POST to the topic URL.\n\nExample:")

                HStack(alignment: .top, spacing: 4) {
                    Text("$")
                    Text("curl -d \"hi\" \(subscription.urlString())")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.body, design: .monospaced))

                Text("Detailed instructions are available on [ntfy.sh](https://ntfy.sh) and [in the docs](https://ntfy.sh/docs).")
            }
        }
    }
    
    private var editButton: some View {
        if editMode == .inactive {
            return Button(action: {
                self.editMode = .active
                self.selection = Set<Notification>()
            }) {
                Text("Select messages")
            }
        } else {
            return Button(action: {
                self.editMode = .inactive
                self.selection = Set<Notification>()
            }) {
                Text("Done")
            }
        }
    }
    
    private func sendTestNotification() {
        guard let baseUrl = subscription.baseUrl else {
            Log.w(tag, "Cannot send test notification: subscription base URL is missing")
            return
        }

        let possibleTags: Array<String> = ["warning", "skull", "success", "triangular_flag_on_post", "de", "us", "dog", "cat", "rotating_light", "bike", "backup", "rsync", "this-s-a-tag", "ios"]
        let priority = Int.random(in: 1..<6)
        let tags = Array(possibleTags.shuffled().prefix(Int.random(in: 0..<4)))

        let user = store.getUser(baseUrl: baseUrl)?.toBasicUser()
        Task {
            do {
                try await ApiService.shared.publish(
                    subscription: subscription,
                    user: user,
                    message: "This is a test notification from the ntfy iOS app. It has a priority of \(priority). If you send another one, it may look different.",
                    title: "Test: You can set a title if you like",
                    priority: priority,
                    tags: tags
                )
                await subscriptionManager.poll(subscription)
            } catch {
                Log.e(tag, "Error sending test notification", error)
            }
        }
    }
    
    private func unsubscribe() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        subscriptionManager.unsubscribe(subscription)
        delegate.selectedBaseUrl = nil
    }

    private func deleteAll() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        store.delete(allNotificationsFor: subscription)
    }

    private func deleteSelected() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        store.delete(notifications: selection)
        selection = Set<Notification>()
        editMode = .inactive
    }
    
    private func cancelSubscriptionNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { notification in
                    let userInfo = notification.request.content.userInfo
                    if let baseUrl = userInfo["base_url"] as? String, let topic = userInfo["topic"] as? String {
                        return baseUrl == subscription.baseUrl && topic == subscription.topic
                    }
                    return false
                }
                .map { notification in
                    notification.request.identifier
                }
            if !ids.isEmpty {
                Log.d(tag, "Cancelling \(ids.count) notification(s) from notification center")
                notificationCenter.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }
    
    private func showCopyConfirmation() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showCopiedConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.25)) {
                showCopiedConfirmation = false
            }
        }
    }
    
}

#Preview {
    let store = Store.preview
    Group {
        let subscriptionWithNotifications = store.makeSubscription(store.context, "stats", Store.sampleMessages["stats"]!)
        let subscriptionWithoutNotifications = store.makeSubscription(store.context, "announcements", Store.sampleMessages["announcements"]!)
        NotificationListView(subscription: subscriptionWithNotifications)
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
            .environmentObject(AppIconManager())
        NotificationListView(subscription: subscriptionWithoutNotifications)
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
            .environmentObject(AppIconManager())
    }
}
