import Foundation
import CoreData
import Combine
import UserNotifications

/// Handles all persistence in the app by storing/loading subscriptions and notifications using Core Data.
/// There are sadly a lot of hacks in here, because I don't quite understand this fully.
class Store: ObservableObject {
    private enum Constants {
        static let kilobyte: Int64 = 1024
        static let megabyte = kilobyte * 1024

        static let autoDownloadNever: Int64 = 0
        static let autoDownloadAlways: Int64 = 1
        static let autoDownload100KB = 100 * kilobyte
        static let autoDownload500KB = 500 * kilobyte
        static let autoDownloadDefault = megabyte
        static let autoDownload5MB = 5 * megabyte
        static let autoDownload10MB = 10 * megabyte
        static let autoDownload50MB = 50 * megabyte
    }

    static let shared = Store()
    static let tag = "Store"
    /// Posted at the end of `hardRefresh()`. `context.refreshAllObjects()` only refreshes stale
    /// property values on managed objects this context already knows about — it does not make a
    /// long-lived `NSFetchedResultsController` discover brand-new rows inserted by another
    /// process (the NSE), since that context never locally "sees" the insert happen. Observables
    /// backed by an FRC that need to pick up cross-process inserts should re-run `performFetch()`
    /// in response to this notification, not just rely on `controllerDidChangeContent`.
    static let didHardRefreshNotification = NSNotification.Name("Store.didHardRefresh")
    static let appGroup = "group.com.victormanuel.ntfy" // Must match app group of ntfy = ntfyNSE targets
    static let modelName = "ntfy" // Must match .xdatamodeld folder
    static let prefKeyDefaultBaseUrl = "defaultBaseUrl"
    static let prefKeyAttachmentAutoDownloadMaxSize = "attachmentAutoDownloadMaxSize"
    static let prefKeyCriticalAlertsEnabled = "criticalAlertsEnabled"
    static let autoDownloadNever = Constants.autoDownloadNever
    static let autoDownloadAlways = Constants.autoDownloadAlways
    static let autoDownload100KB = Constants.autoDownload100KB
    static let autoDownload500KB = Constants.autoDownload500KB
    static let autoDownloadDefault = Constants.autoDownloadDefault
    static let autoDownload5MB = Constants.autoDownload5MB
    static let autoDownload10MB = Constants.autoDownload10MB
    static let autoDownload50MB = Constants.autoDownload50MB
    private static let sharedDefaults = UserDefaults(suiteName: Store.appGroup)!
    private static let sharedDefaultsKeyCriticalAlertsAuthorized = "criticalAlertsAuthorized"
    private static let sharedDefaultsKeyDidBackfillSortRank = "Store.didBackfillSortRank"
    /// Shared with the NSE, which also saves notifications through `saveNotifications`.
    private static let replayTombstones = ReplayTombstones(defaults: sharedDefaults)
    private let container: NSPersistentContainer
    var context: NSManagedObjectContext {
        return container.viewContext
    }
    private var cancellables: Set<AnyCancellable> = []
    /// Unread count across every subscription, kept in sync by `syncBadgeCount()`. Views (e.g. the
    /// tab bar badge) can observe this directly instead of standing up their own fetch of every
    /// notification just to derive a count.
    @Published private(set) var unreadCount: Int = 0
    /// Guards `scheduleReadFlush()` against queueing more than one pending save. Only ever touched
    /// from inside a `context.perform` block, so the context's own queue serializes access.
    private var isReadFlushScheduled = false

    init(inMemory: Bool = false) {
        let storeUrl = (inMemory) ? URL(fileURLWithPath: "/dev/null") : FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)!
            .appendingPathComponent("ntfy.sqlite")
        let description = NSPersistentStoreDescription(url: storeUrl)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true

        // Set up container and observe changes from app extension
        container = NSPersistentContainer(name: Store.modelName)
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { description, error in
            if let error = error {
                Log.e(Store.tag, "Core Data failed to load: \(error.localizedDescription)", error)
            }
        }
        
        // Shortcut for context
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType) // https://stackoverflow.com/a/60362945/1440785
        context.transactionAuthor = Bundle.main.bundlePath.hasSuffix(".appex") ? "ntfy.appex" : "ntfy"
        
        // When a remote change comes in (= the app extension updated entities in Core Data),
        // we force refresh the view with horrible means. Please help me make this better!
        NotificationCenter.default
          .publisher(for: .NSPersistentStoreRemoteChange)
          .sink { value in
              // TODO: this could probably broadcast the name of the channel
              // so that only relevant views can update.
              Log.d(Store.tag, "Remote change detected, refreshing views", value)

              DispatchQueue.main.async {
                  self.hardRefresh()
              }
          }
          .store(in: &cancellables)

        backfillSortRankIfNeeded()
        unreadCount = unreadNotificationCount()
    }

    func rollbackAndRefresh() {
        // Hack: We refresh all objects, since failing to store a notification usually means
        // that the app extension stored the notification first. This is a way to update the
        // UI properly when it is in the foreground and the app extension stores a notification.
        
        context.rollback()
        hardRefresh()
    }

    func hardRefresh() {
        // `refreshAllObjects` only refreshes objects from which the cache is invalid. With a staleness intervall of -1 the cache never invalidates.
        // We set the `stalenessInterval` to 0 to make sure that changes in the app extension get processed correctly.
        // From: https://www.avanderlee.com/swift/core-data-app-extension-data-sharing/
        //
        // TODO(perf): this refreshes every managed object currently registered in the context, which
        // runs on every single remote-change notification (i.e. every NSE-delivered push while the app
        // is foregrounded). Once the object graph is large, consider refreshing only the objects that
        // actually changed instead of the whole context.

        context.stalenessInterval = 0
        context.refreshAllObjects()
        context.stalenessInterval = -1

        // Notifications inserted by the NSE (a separate process, with its own Store instance)
        // never run through this process's save/markRead methods, so unreadCount would otherwise
        // stay stale until some other mutation happened to refresh it.
        syncBadgeCount()

        NotificationCenter.default.post(name: Store.didHardRefreshNotification, object: self)
    }

    /// Existing installs upgrading to this version have every `Subscription.sortRank` at its
    /// migration default of `0`. Backfill each one to its position in the *current* display
    /// order (alphabetical by topic, matching what `SubscriptionsObservable` sorted by before
    /// this feature existed) exactly once, so nobody's topic list visibly reshuffles the moment
    /// they update. Gated by a UserDefaults flag so it never runs a second time.
    private func backfillSortRankIfNeeded() {
        // `Store.sharedDefaults` (app-group backed), not `UserDefaults.standard`: `Store.shared` is
        // instantiated independently in both the app and the NSE extension process, and
        // `UserDefaults.standard` is NOT shared between an app and its extension without an app
        // group. Gating on `.standard` would let the NSE's first launch since an update re-run this
        // backfill and clobber any manual reordering the user had already done in the app.
        guard !Store.sharedDefaults.bool(forKey: Store.sharedDefaultsKeyDidBackfillSortRank) else { return }
        var didSave = false
        context.performAndWait {
            let request = Subscription.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "topic", ascending: true)]
            let subscriptions = (try? context.fetch(request)) ?? []
            for (index, subscription) in subscriptions.enumerated() {
                subscription.sortRank = Double(index)
            }
            do {
                try context.save()
                didSave = true
            } catch {
                Log.w(Store.tag, "Failed to backfill sortRank", error)
            }
        }
        // Only mark this done once the save actually succeeded — a save failure leaves every
        // subscription's rank at the Core Data migration default, and this flag must stay unset
        // so the backfill retries on the next launch instead of being permanently skipped.
        guard didSave else { return }
        Store.sharedDefaults.set(true, forKey: Store.sharedDefaultsKeyDidBackfillSortRank)
    }

    // MARK: Subscriptions
    
    func saveSubscription(baseUrl: String, topic: String) -> Subscription {
        // `context.performAndWait`, not `DispatchQueue.main.sync`: this is called both from a
        // background queue (SubscriptionAddView) and, since TopicSyncCoordinator's reconciliation
        // now genuinely runs on the main actor, from the main thread — where `main.sync` would
        // deadlock instantly. `performAndWait` is reentrant on the context's own queue, and also
        // puts the object's creation on that queue instead of on the caller's thread.
        var subscription: Subscription!
        context.performAndWait {
            // New topics land at the end of the manually-ordered list.
            let maxRank = ((try? context.fetch(Subscription.fetchRequest())) ?? []).map(\.sortRank).max() ?? -1
            subscription = Subscription(context: context)
            subscription.baseUrl = normalizeBaseUrl(baseUrl)
            subscription.topic = topic
            subscription.sortRank = maxRank + 1
            Log.d(Store.tag, "Storing subscription baseUrl=\(subscription.baseUrl ?? "?"), topic=\(topic)")
            try? context.save()
        }
        return subscription
    }
    
    func getSubscription(baseUrl: String, topic: String) -> Subscription? {
        try? fetchSubscription(baseUrl: baseUrl, topic: topic)
    }
    
    func getSubscriptions() -> [Subscription]? {
        // Wrapped in performAndWait like the rest of this class: TopicSyncCoordinator calls this
        // during reconciliation, and a bare `context.fetch` would be a Core Data concurrency
        // violation whenever the caller isn't on the context's confinement queue.
        var subscriptions: [Subscription]?
        context.performAndWait {
            subscriptions = try? context.fetch(Subscription.fetchRequest())
        }
        return subscriptions
    }

    /// - Parameter syncToCloud: `false` when `TopicSyncCoordinator` is applying a change that came
    ///   from another device, so the write isn't mirrored straight back out to iCloud.
    func saveIcon(for subscription: Subscription, icon: String?, syncToCloud: Bool = true) {
        context.performAndWait {
            subscription.icon = (icon?.isEmpty ?? true) ? nil : icon
            try? context.save()
        }
        #if !NTFY_NSE
        // TopicSyncCoordinator (CloudKit-backed) only exists in the main app target: the NSE
        // target has no iCloud/CloudKit entitlement and doesn't compile these sync sources, so
        // this call must be compiled out there. The hop is a real `Task { @MainActor }` rather
        // than `MainActor.assumeIsolated`, because this target builds in Swift 5 mode with no
        // strict-concurrency checking — "the caller is already on the main actor" is an
        // unenforced assumption here, and `assumeIsolated` traps at runtime when it's wrong.
        if syncToCloud {
            Task { @MainActor in
                TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)
            }
        }
        #endif
    }

    /// - Parameter syncToCloud: see `saveIcon(for:icon:syncToCloud:)`.
    func saveDisplayName(for subscription: Subscription, name: String?, syncToCloud: Bool = true) {
        context.performAndWait {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            subscription.customDisplayName = trimmed.isEmpty ? nil : String(trimmed.prefix(64))
            try? context.save()
        }
        #if !NTFY_NSE
        if syncToCloud {
            Task { @MainActor in
                TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)
            }
        }
        #endif
    }

    /// - Parameter syncToCloud: see `saveIcon(for:icon:syncToCloud:)`.
    func saveSortRank(for subscription: Subscription, rank: Double, syncToCloud: Bool = true) {
        context.performAndWait {
            subscription.sortRank = rank
            try? context.save()
        }
        #if !NTFY_NSE
        if syncToCloud {
            Task { @MainActor in
                TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)
            }
        }
        #endif
    }

    func completeAttachmentDownload(notificationID: String, localPath: String, resolvedType: String?, resolvedSize: Int64) {
        context.performAndWait {
            let request = Notification.fetchRequest()
            request.predicate = NSPredicate(format: "id = %@", notificationID)
            guard let notification = try? context.fetch(request).first else {
                return
            }

            notification.attachmentLocalPath = localPath
            notification.attachmentProgress = AttachmentProgressState.done.persistedValue
            if resolvedSize > 0 {
                notification.attachmentSize = resolvedSize
            }
            if let resolvedType, !resolvedType.isEmpty {
                notification.attachmentType = resolvedType
            }
            try? context.save()
        }
    }

    func delete(subscription: Subscription) {
        context.perform {
            if let notifications = subscription.notifications {
                notifications.forEach { notification in
                    guard let notification = notification as? Notification else { return }
                    self.deleteAttachmentLocalFile(for: notification)
                }
            }
            self.context.delete(subscription)
            try? self.context.save()
            self.syncBadgeCount()
        }
    }
    
    // MARK: Notifications
    
    func save(notificationFromMessage message: Message, withSubscription subscription: Subscription) {
        save(notificationsFromMessages: [message], withSubscription: subscription)
    }

    /// Returns nil if there is no subscription for the topic, or saving failed.
    func save(notificationFromMessage message: Message, baseUrl: String, topic: String) -> SavedNotifications? {
        var saved: SavedNotifications?
        context.performAndWait {
            do {
                guard let subscription = try fetchSubscription(baseUrl: baseUrl, topic: topic) else {
                    return
                }
                saved = try saveNotifications([message], withSubscription: subscription)
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
            }
        }
        return saved
    }

    @discardableResult
    func save(notificationsFromMessages messages: [Message], withSubscription subscription: Subscription) -> SavedNotifications {
        guard !messages.isEmpty else { return SavedNotifications() }

        var saved = SavedNotifications()
        context.performAndWait {
            // `subscription` may have been captured before an `await` (e.g. a network round trip
            // in SubscriptionManager.poll) and unsubscribed from in the meantime. Re-checking here,
            // inside the same confinement queue as the delete, closes that race instead of merely
            // narrowing it like the caller's upfront liveness check does.
            guard !subscription.isDeleted, subscription.managedObjectContext != nil else {
                Log.d(Store.tag, "Subscription was removed before notifications could be saved; discarding \(messages.count) message(s)")
                return
            }
            do {
                saved = try saveNotifications(messages, withSubscription: subscription)
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
            }
        }
        return saved
    }

    func delete(notification: Notification) {
        context.performAndWait {
            Log.d(Store.tag, "Deleting notification \(notification.id ?? "")")
            rememberReplayableDeletions([notification])
            deleteAttachmentLocalFile(for: notification)
            context.delete(notification)
            try? context.save()
            syncBadgeCount()
        }
    }

    func delete(notifications: Set<Notification>) {
        context.performAndWait {
            Log.d(Store.tag, "Deleting \(notifications.count) notification(s)")
            rememberReplayableDeletions(Array(notifications))
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

    func delete(allNotificationsFor subscription: Subscription) {
        context.performAndWait {
            guard let notifications = subscription.notifications else { return }
            Log.d(Store.tag, "Deleting all \(notifications.count) notification(s) for subscription \(subscription.urlString())")
            rememberReplayableDeletions(notifications.compactMap { $0 as? Notification })
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

    func deleteAllNotifications() {
        context.performAndWait {
            guard let notifications = try? context.fetch(Notification.fetchRequest()) else { return }
            Log.d(Store.tag, "Deleting all \(notifications.count) notification(s) across all subscriptions")
            rememberReplayableDeletions(notifications)
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

    func markRead(_ notification: Notification) {
        // Read *only* `objectID` on the caller's thread. It is the one property of a managed object
        // that never fires a fault, so it stays safe even when the row behind this object is
        // already gone.
        //
        // That matters because every caller is `NotificationRowView`'s `.onDisappear`, which fires
        // after the row has left the view hierarchy — including when it left *because it was
        // deleted*: swipe-to-delete, "Clear all notifications", "Delete selected", or the cascade
        // from an unsubscribe. By then the row can be deleted and saved, and touching any
        // persistent property of a deleted-and-saved object raises NSObjectInaccessibleException
        // ("could not fulfill a fault"). That is an Objective-C exception, which Swift cannot
        // catch, so it terminates the app rather than surfacing as an error.
        let objectID = notification.objectID
        // `perform`, not `performAndWait`: no caller waits on a return value, and running the
        // mutate + save + badge-count fetch synchronously blocked the main thread on the same run
        // loop turn as the scroll, causing jank.
        context.perform {
            // Re-resolve rather than trusting the captured object. `existingObject(with:)` throws a
            // *Swift* error when the row no longer exists, which we can handle; `isDeleted` covers
            // a delete that has not been saved yet.
            guard
                let notification = try? self.context.existingObject(with: objectID) as? Notification,
                !notification.isDeleted,
                !notification.isRead
            else {
                return
            }
            notification.isRead = true
            Log.d(Store.tag, "Marking notification \(notification.id ?? "?") as read")
            self.scheduleReadFlush()
        }
    }

    /// Coalesces `markRead` flips into one save per run-loop turn.
    ///
    /// `onDisappear` fires per row, so a fast scroll produces a burst of them and *dismissing* a
    /// list fires one for every row still on screen, all within a single turn. Saving inside each
    /// `markRead` meant N `context.save()` calls plus N `unreadNotificationCount()` fetches back to
    /// back — and, worse, N separate FRC change notifications, so the list re-diffed and re-laid
    /// out N times mid-gesture. Batching them keeps the semantics identical (every flip still
    /// lands) while collapsing that into one save and one FRC notification.
    private func scheduleReadFlush() {
        guard !isReadFlushScheduled else { return }
        isReadFlushScheduled = true
        // Enqueued from inside a `context.perform` block, so it runs after every `markRead` block
        // already queued this turn — i.e. after the whole burst has flipped its flags.
        context.perform {
            self.isReadFlushScheduled = false
            if self.context.hasChanges {
                do {
                    try self.context.save()
                } catch {
                    Log.w(Store.tag, "Failed to save isRead flags", error)
                }
            }
            // Outside the `hasChanges` check: another save on this context may already have
            // flushed these flips, and the badge still has to catch up with them.
            self.syncBadgeCount()
        }
    }

    func unreadNotificationCount() -> Int {
        var count = 0
        context.performAndWait {
            let request = Notification.fetchRequest()
            request.predicate = NSPredicate(format: "isRead == %@", NSNumber(value: false))
            count = (try? context.count(for: request)) ?? 0
        }
        return count
    }

    func syncBadgeCount() {
        let count = unreadNotificationCount()
        unreadCount = count
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().setBadgeCount(count)
        }
    }

    // MARK: Users
    
    func saveUser(baseUrl: String, username: String, password: String) {
        context.perform {
            do {
                let user = self.getUser(baseUrl: baseUrl) ?? User(context: self.context)
                user.baseUrl = normalizeBaseUrl(baseUrl)
                user.username = username
                user.password = password
                try self.context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot store user", error)
                self.rollbackAndRefresh()
            }
        }
    }
    
    func getUser(baseUrl: String) -> User? {
        try? fetchUser(baseUrl: baseUrl)
    }

    func getBasicUser(baseUrl: String) -> BasicUser? {
        var basicUser: BasicUser?
        context.performAndWait {
            basicUser = try? fetchUser(baseUrl: baseUrl)?.toBasicUser()
        }
        return basicUser
    }

    func findSubscriptionMatch(forPollRequestTopic topic: String, preferredBaseUrl: String? = nil) -> (baseUrl: String, topic: String)? {
        var match: (baseUrl: String, topic: String)?
        context.performAndWait {
            guard let subscriptions = try? context.fetch(Subscription.fetchRequest()) else {
                Log.w(Store.tag, "\(#function): Can't find subscriptions with topic=\(topic)")
                return
            }
            let normalizedPreferredBaseUrl = preferredBaseUrl.map(normalizeBaseUrl)
            let normalizedDefaultBaseUrl = normalizeBaseUrl(Config.appBaseUrl)
            let matchingSubscriptions = subscriptions.filter {
                $0.urlHash() == topic || $0.topic == topic
            }
            Log.d(
                Store.tag,
                "\(#function) topic=\(topic) matched \(matchingSubscriptions.count) subscription(s)",
                matchingSubscriptions.compactMap { subscription -> String? in
                    guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else {
                        return nil
                    }
                    return topicUrl(baseUrl: baseUrl, topic: topic)
                }
            )

            let prioritizedMatch = matchingSubscriptions.first {
                guard let baseUrl = $0.baseUrl else {
                    return false
                }
                if let normalizedPreferredBaseUrl {
                    return normalizeBaseUrl(baseUrl) == normalizedPreferredBaseUrl
                }
                return false
            } ?? matchingSubscriptions.first {
                guard let baseUrl = $0.baseUrl, let subscriptionTopic = $0.topic else {
                    return false
                }
                return subscriptionTopic == topic && normalizeBaseUrl(baseUrl) == normalizedDefaultBaseUrl
            } ?? matchingSubscriptions.first

            match = prioritizedMatch.flatMap { subscription in
                guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else {
                    return nil
                }
                return (baseUrl, topic)
            }
            if match == nil {
                Log.w(
                    Store.tag,
                    "\(#function) No poll request subscription match topic=\(topic) and preferredBaseUrl=\(normalizedPreferredBaseUrl ?? "<nil>")"
                )
            }
        }
        return match
    }
    
    func delete(user: User) {
        context.delete(user)
        try? context.save()
    }
    
    // MARK: Preferences
    
    func saveDefaultBaseUrl(baseUrl: String?) {
        do {
            let pref = getPreference(key: Store.prefKeyDefaultBaseUrl) ?? Preference(context: context)
            pref.key = Store.prefKeyDefaultBaseUrl
            pref.value = baseUrl.map(normalizeBaseUrl) ?? Config.appBaseUrl
            try context.save()
        } catch let error {
            Log.w(Store.tag, "Cannot store preference", error)
            rollbackAndRefresh()
        }
    }
    
    func getDefaultBaseUrl() -> String {
        let baseUrl = getPreference(key: Store.prefKeyDefaultBaseUrl)?.value
        if baseUrl == nil || baseUrl?.isEmpty == true {
            return Config.appBaseUrl
        }
        return normalizeBaseUrl(baseUrl!)
    }

    func getAttachmentAutoDownloadMaxSize() -> Int64 {
        guard
            let rawValue = getPreference(key: Store.prefKeyAttachmentAutoDownloadMaxSize)?.value,
            let maxSize = Int64(rawValue)
        else {
            return Store.autoDownloadDefault
        }
        return maxSize
    }

    func saveAttachmentAutoDownloadMaxSize(_ maxSize: Int64) {
        do {
            let pref = getPreference(key: Store.prefKeyAttachmentAutoDownloadMaxSize) ?? Preference(context: context)
            pref.key = Store.prefKeyAttachmentAutoDownloadMaxSize
            pref.value = String(maxSize)
            try context.save()
        } catch let error {
            Log.w(Store.tag, "Cannot store attachment auto-download preference", error)
            rollbackAndRefresh()
        }
    }

    func getCriticalAlertsEnabled() -> Bool {
        getPreference(key: Store.prefKeyCriticalAlertsEnabled)?.value == "true"
    }

    func saveCriticalAlertsEnabled(_ enabled: Bool) {
        do {
            let pref = getPreference(key: Store.prefKeyCriticalAlertsEnabled) ?? Preference(context: context)
            pref.key = Store.prefKeyCriticalAlertsEnabled
            pref.value = String(enabled)
            try context.save()
        } catch let error {
            Log.w(Store.tag, "Cannot store critical alerts preference", error)
            rollbackAndRefresh()
        }
    }

    static func getCriticalAlertsAuthorized() -> Bool {
        sharedDefaults.bool(forKey: sharedDefaultsKeyCriticalAlertsAuthorized)
    }

    static func saveCriticalAlertsAuthorized(_ enabled: Bool) {
        sharedDefaults.set(enabled, forKey: sharedDefaultsKeyCriticalAlertsAuthorized)
    }

    func shouldAutoDownloadAttachment(_ attachment: MessageAttachment) -> Bool {
        if attachment.isExpired() {
            return false
        }

        let maxSize = getAttachmentAutoDownloadMaxSize()
        if maxSize == Store.autoDownloadNever {
            return false
        }
        if maxSize == Store.autoDownloadAlways {
            return true
        }
        guard let size = attachment.size else {
            return true
        }
        return size <= maxSize
    }

    func resolvedAttachmentAutoDownloadMaxSize() -> Int64? {
        let maxSize = getAttachmentAutoDownloadMaxSize()
        if maxSize == Store.autoDownloadAlways {
            return nil
        }
        return maxSize
    }
    
    private func getPreference(key: String) -> Preference? {
        let request = Preference.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "key = %@", key)])
        return try? context.fetch(request).first
    }

    private func fetchSubscription(baseUrl: String, topic: String) throws -> Subscription? {
        let fetchRequest = Subscription.fetchRequest()
        let baseUrlPredicate = NSPredicate(format: "baseUrl = %@", normalizeBaseUrl(baseUrl))
        let topicPredicate = NSPredicate(format: "topic = %@", topic)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [baseUrlPredicate, topicPredicate])
        return try context.fetch(fetchRequest).first
    }

    private func fetchUser(baseUrl: String) throws -> User? {
        let request = User.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "baseUrl = %@", normalizeBaseUrl(baseUrl))])
        return try context.fetch(request).first
    }

    /// Applies `messages` in order. A `message` replaces the stored versions of its sequence (unless
    /// a newer one is stored already), `message_delete` deletes them and `message_clear` marks them
    /// read. Other events, e.g. `poll_request`, are ignored.
    private func saveNotifications(_ messages: [Message], withSubscription subscription: Subscription) throws -> SavedNotifications {
        let ids = messages.map(\.id)
        let existingRequest = Notification.fetchRequest()
        existingRequest.predicate = NSPredicate(format: "id IN %@", ids)
        let existingNotifications = try context.fetch(existingRequest)
        let existingIDs = Set(existingNotifications.compactMap(\.id))
        // Tombstoned IDs were deleted here (or are events applied already) but can be replayed by
        // `since=<id>` (see `ReplayTombstones`).
        let newMessages = messages.filter { message in
            !existingIDs.contains(message.id) && !Store.replayTombstones.contains(message.id)
        }

        var saved = SavedNotifications()
        var appliedEvents: [String: Int64] = [:]
        for message in newMessages {
            let sequenceId = message.effectiveSequenceId
            switch message.event {
            case "message":
                let versions = try fetchNotifications(sequenceId: sequenceId, subscription: subscription)
                if versions.contains(where: { $0.time > message.time }) {
                    Log.d(Store.tag, "Skipping notification \(message.id), a newer version of sequence \(sequenceId) is stored")
                    continue
                }
                deleteVersions(versions)
                insertNotification(from: message, subscription: subscription)
                saved.shown.removeAll { $0.effectiveSequenceId == sequenceId }
                saved.shown.append(message)
            case "message_delete":
                let versions = try fetchNotifications(sequenceId: sequenceId, subscription: subscription)
                Log.d(Store.tag, "Deleting \(versions.count) notification(s) of sequence \(sequenceId)")
                deleteVersions(versions)
                saved.dismiss(sequenceId: sequenceId)
                appliedEvents[message.id] = message.time
            case "message_clear":
                let versions = try fetchNotifications(sequenceId: sequenceId, subscription: subscription)
                Log.d(Store.tag, "Marking \(versions.count) notification(s) of sequence \(sequenceId) as read")
                versions.forEach { $0.isRead = true }
                saved.dismiss(sequenceId: sequenceId)
                appliedEvents[message.id] = message.time
            default:
                continue
            }
        }
        // A replayed delete or clear must not hit a newer version stored since it was applied
        Store.replayTombstones.add(appliedEvents)

        if let lastMessage = messages.last {
            subscription.lastNotificationId = lastMessage.id
        }
        try context.save()
        if !newMessages.isEmpty {
            syncBadgeCount()
        }
        return saved
    }

    /// The stored versions of a sequence. Notifications stored before sequence IDs existed have none,
    /// and their message ID is their sequence ID.
    private func fetchNotifications(sequenceId: String, subscription: Subscription) throws -> [Notification] {
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(
            format: "subscription == %@ AND (sequenceId == %@ OR (sequenceId == nil AND id == %@))",
            subscription, sequenceId, sequenceId
        )
        return try context.fetch(request).filter { !$0.isDeleted }
    }

    private func deleteVersions(_ versions: [Notification]) {
        guard !versions.isEmpty else { return }
        rememberReplayableDeletions(versions)
        versions.forEach { notification in
            deleteAttachmentLocalFile(for: notification)
            context.delete(notification)
        }
    }

    private func insertNotification(from message: Message, subscription: Subscription) {
        let notification = Notification(context: context)
        notification.id = message.id
        notification.sequenceId = message.effectiveSequenceId
        notification.time = message.time
        notification.message = message.message ?? ""
        notification.title = message.title ?? ""
        notification.priority = (message.priority != nil && message.priority != 0) ? message.priority! : 3
        notification.tags = message.tags?.joined(separator: ",") ?? ""
        notification.actions = Actions.shared.encode(message.actions)
        notification.click = message.click ?? ""
        notification.contentType = message.contentType
        notification.icon = message.iconUrl?.absoluteString
        notification.attachmentName = message.attachment?.name
        notification.attachmentType = message.attachment?.type
        notification.attachmentSize = message.attachment?.size ?? 0
        notification.attachmentExpires = message.attachment?.expires ?? 0
        notification.attachmentUrl = message.attachment?.url
        if
            let attachment = message.attachment,
            let remoteUrl = URL(string: attachment.url),
            let localFileUrl = AttachmentFileStore.existingLocalFileUrl(
                notificationID: message.id,
                remoteUrl: remoteUrl,
                attachment: attachment,
                mimeType: attachment.type
            )
        {
            notification.attachmentLocalPath = localFileUrl.path
            notification.attachmentProgress = AttachmentProgressState.done.persistedValue
        } else {
            notification.attachmentProgress = message.attachment == nil ? 0 : AttachmentProgressState.none.persistedValue
        }
        notification.subscription = subscription
        subscription.addToNotifications(notification)
        Log.d(Store.tag, "Storing notification with ID \(notification.id ?? "<unknown>")")
    }

    /// Remembers deleted notifications that a `since=<id>` poll can return again: those from the
    /// newest second of their subscription, which is where the poll marker sits. Must be called
    /// before the notifications are deleted, while their subscription is still reachable.
    private func rememberReplayableDeletions(_ notifications: [Notification]) {
        var entries: [String: Int64] = [:]
        let bySubscription = Dictionary(grouping: notifications) { $0.subscription?.objectID }
        for (_, group) in bySubscription {
            let newestTime = group.first?.subscription?.notifications?
                .compactMap { ($0 as? Notification)?.time }
                .max() ?? group.map(\.time).max() ?? 0
            for notification in group where notification.time >= newestTime {
                if let id = notification.id {
                    entries[id] = notification.time
                }
            }
        }
        Store.replayTombstones.add(entries)
    }

    private func deleteAttachmentLocalFile(for notification: Notification) {
        if let localPath = notification.attachmentLocalPath, !localPath.isEmpty {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: localPath))
            notification.attachmentLocalPath = nil
        }
    }
}

/// What saving messages changed, so that the system notifications can follow.
struct SavedNotifications {
    /// The new or updated notifications to show, at most one per sequence, oldest first.
    var shown: [Message] = []
    /// Sequences that were deleted or cleared, whose system notifications should go away.
    var dismissedSequenceIds: [String] = []

    /// Sequences whose delivered system notifications are outdated: dismissed ones, and the ones
    /// with a new version to show.
    var outdatedSequenceIds: Set<String> {
        Set(dismissedSequenceIds).union(shown.map(\.effectiveSequenceId))
    }

    fileprivate mutating func dismiss(sequenceId: String) {
        shown.removeAll { $0.effectiveSequenceId == sequenceId }
        if !dismissedSequenceIds.contains(sequenceId) {
            dismissedSequenceIds.append(sequenceId)
        }
    }
}

/// Since ntfy v2.31, a `since=<id>` poll also returns the messages published in the same second as
/// the marker, including ones written before it, so that none are skipped when several servers
/// write out of order. Messages the app still has are dropped by ID, but ones the user deleted would
/// come back and notify again. This remembers those deleted IDs, with their message time.
struct ReplayTombstones {
    static let maxEntries = 500
    static let maxAge: Int64 = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String = "Store.replayTombstones") {
        self.defaults = defaults
        self.key = key
    }

    func contains(_ id: String) -> Bool {
        return load()[id] != nil
    }

    /// Adds `entries` (message ID to message time), dropping entries older than `maxAge` and
    /// keeping only the newest `maxEntries`. Old messages can no longer be replayed: the marker
    /// only moves forward, and servers expire their message cache.
    func add(_ entries: [String: Int64], now: Int64 = Int64(Date().timeIntervalSince1970)) {
        guard !entries.isEmpty else { return }
        let merged = load().merging(entries) { _, new in new }
            .filter { now - $0.value <= Self.maxAge }
        let kept = merged.count <= Self.maxEntries
            ? merged
            : Dictionary(uniqueKeysWithValues: merged.sorted { $0.value > $1.value }.prefix(Self.maxEntries).map { ($0.key, $0.value) })
        defaults.set(kept.mapValues { NSNumber(value: $0) }, forKey: key)
    }

    private func load() -> [String: Int64] {
        guard let stored = defaults.dictionary(forKey: key) as? [String: NSNumber] else { return [:] }
        return stored.mapValues(\.int64Value)
    }
}

extension Store {
    static let sampleMessages = [
        "stats": [
            // TODO: Message with action
            Message(id: "1", time: 1653048956, event: "message", topic: "stats", message: "In the last 24 hours, hyou had 5,000 users across 13 countries visit your website", title: "Record visitor numbers", priority: 4, tags: ["smile", "server123", "de"], actions: nil),
            Message(id: "2", time: 1653058956, event: "message", topic: "stats", message: "201 users/h\n80 IPs", title: "This is a title", priority: 1, tags: [], actions: nil),
            Message(id: "3", time: 1643058956, event: "message", topic: "stats", message: "This message does not have a title, but is instead super long. Like really really long. It can't be any longer I think. I mean, there is s 4,000 byte limit of the message, so I guess I have to make this 4,000 bytes long. Or do I? 😁 I don't know. It's quite tedious to come up with something so long, so I'll stop now. Bye!", title: nil, priority: 5, tags: ["facepalm"], actions: nil)
        ],
        "backups": [],
        "announcements": [
            Message(id: "md1", time: 1653048956, event: "message", topic: "announcements", message: "**Bold**, *italic*, ~~strike~~ and `inline code` all render. Plus a [link](https://ntfy.sh) and a bare URL https://docs.ntfy.sh\n\n- first item\n- second item", title: "Markdown release 🎉", priority: 3, tags: ["tada"], actions: nil, contentType: "text/markdown")
        ],
        "alerts": [],
        "playground": []
    ]
    
    static var preview: Store = {
        let store = Store(inMemory: true)
        store.context.perform {
            // Subscriptions and notifications
            sampleMessages.forEach { topic, messages in
                store.makeSubscription(store.context, topic, messages)
            }
            
            // Users
            store.saveUser(baseUrl: "https://ntfy.sh", username: "testuser", password: "testuser")
            store.saveUser(baseUrl: "https://ntfy.example.com", username: "phil", password: "phil12")
        }
        return store
    }()
    
    static var previewEmpty: Store = {
        return Store(inMemory: true)
    }()
    
    @discardableResult
    func makeSubscription(_ context: NSManagedObjectContext, _ topic: String, _ messages: [Message]) -> Subscription {
        let notifications = messages.map { message in
            let notification = Notification(context: context)
            notification.id = message.id
            notification.time = message.time
            notification.message = message.message
            notification.title = message.title
            notification.priority = message.priority ?? 3
            notification.tags = message.tags?.joined(separator: ",") ?? ""
            notification.contentType = message.contentType
            notification.attachmentName = message.attachment?.name
            notification.attachmentType = message.attachment?.type
            notification.attachmentSize = message.attachment?.size ?? 0
            notification.attachmentExpires = message.attachment?.expires ?? 0
            notification.attachmentUrl = message.attachment?.url
            notification.attachmentProgress = message.attachment == nil ? 0 : AttachmentProgressState.none.persistedValue
            return notification
        }
        let subscription = Subscription(context: context)
        subscription.baseUrl = Config.appBaseUrl
        subscription.topic = topic
        subscription.notifications = NSSet(array: notifications)
        return subscription
    }
}
