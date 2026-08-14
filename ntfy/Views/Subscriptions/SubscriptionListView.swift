import SwiftUI
import CoreData
import UserNotifications

enum NotificationsRoute: Hashable {
    case all
    case topic(Subscription)
}

struct SubscriptionListView: View {
    let tag = "SubscriptionList"

    @EnvironmentObject private var store: Store
    @Environment(AppDelegate.self) private var delegate
    @StateObject var subscriptionsModel = SubscriptionsObservable()
    @StateObject var allNotificationsModel = AllNotificationsObservable()
    @State private var showingAddDialog = false
    @State private var path: [NotificationsRoute] = []

    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }

    var body: some View {
        NavigationStack(path: $path) {
            subscriptionList
                .navigationDestination(for: NotificationsRoute.self) { route in
                    switch route {
                    case .all:
                        AllNotificationsView(notificationsModel: allNotificationsModel)
                    case .topic(let subscription):
                        NotificationListView(subscription: subscription)
                    }
                }
        }
        .onChange(of: delegate.selectedBaseUrl) { _, newValue in
            guard
                let newValue,
                let subscription = subscriptionsModel.subscriptions.first(where: { $0.urlString() == newValue })
            else {
                return
            }
            path = [.topic(subscription)]
        }
    }

    private var subscriptionList: some View {
        List {
            if !subscriptionsModel.subscriptions.isEmpty {
                NavigationLink(value: NotificationsRoute.all) {
                    AllNotificationsRowView(
                        notificationsModel: allNotificationsModel,
                        topicCount: subscriptionsModel.subscriptions.count
                    )
                }
            }
            ForEach(subscriptionsModel.subscriptions) { subscription in
                SubscriptionItemNavView(subscription: subscription)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await pollSubscriptions()
        }
        .navigationTitle("Subscribed topics")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    self.showingAddDialog = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if subscriptionsModel.subscriptions.isEmpty {
                emptyState
            }
        }
        .sheet(isPresented: $showingAddDialog) {
            SubscriptionAddView(isShowing: $showingAddDialog)
        }
        .onAppear {
            // Ensures subscription count stays up to date, so a pull to refresh isn't required
            Task {
                await pollSubscriptions()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No subscriptions yet", systemImage: "tray")
        } description: {
            Text("Tap + to subscribe to a topic. You'll get notified whenever a message is sent to it via PUT or POST.\n\nDetailed instructions are available on [ntfy.sh](https://ntfy.sh) and [in the docs](https://ntfy.sh/docs).")
        }
    }

    private func pollSubscriptions() async {
        let subscriptionManager = subscriptionManager
        await withTaskGroup(of: Void.self) { group in
            for subscription in subscriptionsModel.subscriptions {
                group.addTask {
                    await subscriptionManager.poll(subscription)
                }
            }
        }
    }
}

struct SubscriptionItemNavView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var subscription: Subscription
    @State private var unsubscribeAlert = false

    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }

    var body: some View {
        NavigationLink(value: NotificationsRoute.topic(subscription)) {
            SubscriptionItemRowView(subscription: subscription)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                self.unsubscribeAlert = true
            } label: {
                Label("Delete", systemImage: "trash.circle")
            }
        }
        .alert(isPresented: $unsubscribeAlert) {
            Alert(
                title: Text("Unsubscribe"),
                message: Text("Do you really want to unsubscribe from this topic and delete all of the notifications you received?"),
                primaryButton: .destructive(
                    Text("Unsubscribe"),
                    action: {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        self.subscriptionManager.unsubscribe(subscription)
                        self.unsubscribeAlert = false
                    }
                ),
                secondaryButton: .cancel()
            )
        }
    }
}

struct SubscriptionItemRowView: View {
    @ObservedObject var subscription: Subscription
    @StateObject private var notificationsModel: NotificationsObservable
    @State private var showEditor = false

    init(subscription: Subscription) {
        self.subscription = subscription
        _notificationsModel = StateObject(wrappedValue: NotificationsObservable(subscriptionID: subscription.objectID))
    }

    private var isDefaultServer: Bool {
        guard let baseUrl = subscription.baseUrl else { return true }
        return normalizeBaseUrl(baseUrl) == normalizeBaseUrl(Config.appBaseUrl)
    }

    // notificationsModel.notifications is already sorted by time descending
    private var unreadCount: Int {
        notificationsModel.notifications.reduce(0) { $1.isRead ? $0 : $0 + 1 }
    }

    var body: some View {
        let totalNotificationCount = notificationsModel.notifications.count
        HStack(spacing: 12) {
            Button {
                showEditor = true
            } label: {
                TopicAvatarView(name: subscription.topicName(), emoji: subscription.icon)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(subscription.displayName())
                            .font(.headline)
                            .lineLimit(1)
                        if !isDefaultServer, let baseUrl = subscription.baseUrl {
                            Text(shortUrl(url: baseUrl))
                                .font(.caption)
                                .foregroundStyle(.gray)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(notificationsModel.notifications.first?.shortDateTime() ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
                HStack {
                    Text("\(totalNotificationCount) notification\(totalNotificationCount != 1 ? "s" : "")")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                    if unreadCount > 0 {
                        Spacer()
                        UnreadDotView()
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showEditor) {
            TopicEditorView(subscription: subscription)
        }
    }
}

struct AllNotificationsRowView: View {
    @EnvironmentObject private var iconManager: AppIconManager
    @ObservedObject var notificationsModel: AllNotificationsObservable
    let topicCount: Int

    private var unreadCount: Int {
        notificationsModel.notifications.reduce(0) { $1.isRead ? $0 : $0 + 1 }
    }

    var body: some View {
        let notifications = notificationsModel.notifications
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconManager.current.accentColor)
                    .frame(width: 40, height: 40)
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("All Notifications")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    // notifications is already sorted by time descending
                    Text(notifications.first?.shortDateTime() ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
                HStack {
                    Text("\(notifications.count) notification\(notifications.count != 1 ? "s" : "") across \(topicCount) topic\(topicCount != 1 ? "s" : "")")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                    if unreadCount > 0 {
                        Spacer()
                        UnreadDotView()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct TopicAvatarView: View {
    let name: String
    var emoji: String? = nil

    private var initial: String {
        String(name.first ?? "?").uppercased()
    }

    private var color: Color {
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 40, height: 40)
            if let emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 20))
            } else {
                Text(initial)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

struct UnreadDotView: View {
    @EnvironmentObject private var iconManager: AppIconManager

    var body: some View {
        Circle()
            .fill(iconManager.current.accentColor)
            .frame(width: 8, height: 8)
    }
}

#Preview {
    let store = Store.preview // Store.previewEmpty
    SubscriptionListView()
        .environment(\.managedObjectContext, store.context)
        .environmentObject(store)
        .environmentObject(AppIconManager())
        .environment(AppDelegate())
}
