import CloudKit
import Combine
import CoreData

/// A second, independent Core Data stack, separate from `Store`, that mirrors subscribed-topic
/// metadata (server, topic, display name, icon) to the user's private CloudKit database. Kept
/// completely separate from `Store`'s `Subscription`/`Notification` model: Core Data relationships
/// can't span two CloudKit configurations, and this app explicitly does not want notification
/// history or credentials syncing to iCloud. See
/// docs/superpowers/specs/2026-08-21-icloud-topic-sync-design.md for the full rationale.
final class TopicSyncStore {
    static let shared = TopicSyncStore()
    static let tag = "TopicSyncStore"
    /// Posted whenever a remote (cross-device) change is detected. `TopicSyncCoordinator`
    /// listens for this to trigger reconciliation.
    static let didChangeNotification = NSNotification.Name("TopicSyncStore.didChange")
    /// Posted when the active iCloud account actually changed (sign-out, sign-in, or a switch to a
    /// different Apple Account). `TopicSyncCoordinator` listens for this to re-reconcile against
    /// the *new* account rather than treat the now-empty local replica as "unsubscribed elsewhere."
    static let accountChangedNotification = NSNotification.Name("TopicSyncStore.accountChanged")

    /// Coarse "is topic sync actually working?" summary for the Settings status row. Being signed
    /// into iCloud is necessary but not sufficient — the mirrored store also has to have loaded.
    enum SyncStatus {
        case notSignedIn
        case signedInButNotSyncing
        case synced
    }

    private static let containerIdentifier = "iCloud.com.victormanuel.ntfy" // must match Task 3's container
    private static let ubiquityTokenDefaultsKey = "TopicSyncStore.lastUbiquityIdentityToken"

    private let container: NSPersistentCloudKitContainer
    private let inMemory: Bool
    var context: NSManagedObjectContext { container.viewContext }
    private var cancellables: Set<AnyCancellable> = []

    /// `loadPersistentStores`' completion handler can in principle run asynchronously (and the
    /// flag is read from the main actor while being written from wherever Core Data calls back),
    /// so guard it with a lock rather than assuming synchronous, same-thread delivery.
    private let stateLock = NSLock()
    private var storeLoadedSuccessfullyStorage = false

    /// True only once `loadPersistentStores` reported success for this container. Callers must
    /// consult this before interpreting an empty `allSyncedTopics()` result: without it, "the
    /// store failed to load" and "every topic was unsubscribed on another device" are
    /// indistinguishable, and acting on the latter destroys local subscriptions.
    var storeLoadedSuccessfully: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storeLoadedSuccessfullyStorage
    }

    var syncStatus: SyncStatus {
        guard FileManager.default.ubiquityIdentityToken != nil else { return .notSignedIn }
        return storeLoadedSuccessfully ? .synced : .signedInButNotSyncing
    }

    init(inMemory: Bool = false) {
        self.inMemory = inMemory
        container = NSPersistentCloudKitContainer(name: "TopicSync")

        if inMemory {
            let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
            // In-memory stores can't mirror to CloudKit — this path exists purely for fast,
            // deterministic unit tests of the CRUD methods below.
            description.cloudKitContainerOptions = nil
            container.persistentStoreDescriptions = [description]
        } else if let description = container.persistentStoreDescriptions.first {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerIdentifier)
        }

        loadStores()
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)

        guard !inMemory else { return }

        #if DEBUG
        // Permanent regression guard. `initializeCloudKitSchema` validates the managed object
        // model against everything CloudKit mirroring requires (all attributes optional or
        // defaulted, no uniqueness constraints, no non-optional relationships, ...) and throws if
        // the model is unusable. `.dryRun` means it only builds the representative records locally
        // and never uploads anything, so it's safe to run on every debug launch. Without this, an
        // invalid model fails silently: the local SQLite store loads, the app looks fine, and
        // nothing ever syncs.
        do {
            try container.initializeCloudKitSchema(options: [.dryRun])
        } catch {
            Log.e(Self.tag, "TopicSync model is NOT valid for CloudKit mirroring — sync will silently not work: \(error.localizedDescription)", error)
        }
        #endif

        // Seed the last-seen ubiquity token on first run so the very first CKAccountChanged
        // doesn't look like a nil -> non-nil account switch and needlessly wipe the replica.
        if UserDefaults.standard.data(forKey: Self.ubiquityTokenDefaultsKey) == nil {
            persistUbiquityToken(FileManager.default.ubiquityIdentityToken)
        }

        NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .sink { [weak self] _ in
                guard let self else { return }
                self.context.perform { self.context.refreshAllObjects() }
                NotificationCenter.default.post(name: TopicSyncStore.didChangeNotification, object: self)
            }
            .store(in: &cancellables)

        // Apple's documented signal for "the iCloud account changed" is CKAccountChanged, not a
        // failed CloudKit setup event: setup can fail for plenty of reasons that have nothing to
        // do with an account switch (offline at launch, not signed in at all, transient retries),
        // and reacting to those by wiping the local replica is destructive.
        NotificationCenter.default
            .publisher(for: .CKAccountChanged)
            // CKAccountChanged is posted from CloudKit's own queue; hop to main so the store
            // teardown/reload in clearLocalReplica() doesn't race the main-actor coordinator.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleAccountChanged() }
            .store(in: &cancellables)

        // Kept purely as a diagnostic — deliberately no side effects. See above.
        NotificationCenter.default
            .publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .compactMap { $0.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event }
            .filter { $0.type == .setup && $0.succeeded == false }
            .sink { event in
                Log.w(TopicSyncStore.tag, "CloudKit setup event reported failure: \(event.error?.localizedDescription ?? "<no error>")")
            }
            .store(in: &cancellables)
    }

    /// Returns every synced topic, after collapsing `(baseUrl, topic)` duplicates.
    ///
    /// Duplicates are real and expected: the `recordName` attribute is *not* what determines a
    /// mirrored object's `CKRecord.ID` (Core Data derives that from the managed object's own
    /// identity), so two devices that each create the same topic while offline produce two
    /// distinct CloudKit records that both mirror down here. `upsert`'s fetch-by-recordName only
    /// ever updates one of them, so without this pass the duplicate would persist forever.
    func allSyncedTopics() -> [SyncedTopic] {
        var result: [SyncedTopic] = []
        context.performAndWait {
            let request = SyncedTopic.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
            let topics = (try? context.fetch(request)) ?? []
            result = deduplicate(topics)
        }
        return result
    }

    func upsert(baseUrl: String, topic: String, customDisplayName: String?, icon: String?) {
        context.performAndWait {
            let recordName = "\(baseUrl)|\(topic)"
            let syncedTopic = (try? fetchByRecordName(recordName)) ?? SyncedTopic(context: context)
            syncedTopic.recordName = recordName
            syncedTopic.baseUrl = baseUrl
            syncedTopic.topic = topic
            syncedTopic.customDisplayName = customDisplayName
            syncedTopic.icon = icon
            syncedTopic.lastModified = Date()
            try? context.save()
        }
    }

    func remove(baseUrl: String, topic: String) {
        context.performAndWait {
            guard let syncedTopic = try? fetchByRecordName("\(baseUrl)|\(topic)") else { return }
            context.delete(syncedTopic)
            try? context.save()
        }
    }

    private func fetchByRecordName(_ recordName: String) throws -> SyncedTopic? {
        let request = SyncedTopic.fetchRequest()
        request.predicate = NSPredicate(format: "recordName == %@", recordName)
        return try context.fetch(request).first
    }

    /// Keeps, per `(baseUrl, topic)`, only the row with the newest `lastModified`, and deletes the
    /// rest. Rows missing a `baseUrl`/`topic` are excluded from the result (they can't be matched
    /// against a local subscription and would otherwise reconcile as a bogus `("", "")` topic) but
    /// are deliberately not deleted — they may be a partially-imported CloudKit record.
    ///
    /// The losers are deleted through the mirrored `viewContext`, which does export a CloudKit
    /// delete. That is intentional and correct here (unlike `clearLocalReplica`): a duplicate
    /// record is genuine garbage that no user ever asked for, and it should disappear everywhere,
    /// not just locally. Every device runs the same "newest lastModified wins" rule, so they
    /// converge on deleting the same loser rather than deleting each other's winner.
    /// Must be called from inside `context.performAndWait`.
    private func deduplicate(_ topics: [SyncedTopic]) -> [SyncedTopic] {
        var winners: [TopicIdentity: SyncedTopic] = [:]
        var losers: Set<ObjectIdentifier> = []
        var usable: [SyncedTopic] = []

        for syncedTopic in topics {
            guard let baseUrl = syncedTopic.baseUrl, let topic = syncedTopic.topic else {
                Log.w(Self.tag, "Ignoring SyncedTopic row with missing baseUrl/topic (recordName=\(syncedTopic.recordName ?? "<nil>"))")
                continue
            }
            usable.append(syncedTopic)
            let identity = TopicIdentity(baseUrl: baseUrl, topic: topic)
            guard let incumbent = winners[identity] else {
                winners[identity] = syncedTopic
                continue
            }
            if (syncedTopic.lastModified ?? .distantPast) > (incumbent.lastModified ?? .distantPast) {
                winners[identity] = syncedTopic
                losers.insert(ObjectIdentifier(incumbent))
            } else {
                losers.insert(ObjectIdentifier(syncedTopic))
            }
        }

        guard !losers.isEmpty else { return usable }

        let survivors = usable.filter { !losers.contains(ObjectIdentifier($0)) }
        Log.w(Self.tag, "Removing \(losers.count) duplicate SyncedTopic row(s)")
        for syncedTopic in usable where losers.contains(ObjectIdentifier(syncedTopic)) {
            context.delete(syncedTopic)
        }
        try? context.save()
        return survivors
    }

    // MARK: - Account changes

    private func handleAccountChanged() {
        let current = FileManager.default.ubiquityIdentityToken
        let previous = loadPersistedUbiquityToken()
        let changed: Bool
        switch (previous, current) {
        case (nil, nil):
            changed = false
        case let (previous?, current?):
            changed = !previous.isEqual(current)
        default:
            changed = true // nil -> signed in, or signed in -> nil
        }
        persistUbiquityToken(current)
        guard changed else {
            Log.d(Self.tag, "CKAccountChanged fired but the ubiquity identity token is unchanged; ignoring")
            return
        }
        Log.w(Self.tag, "iCloud account changed; discarding the local topic-sync replica")
        clearLocalReplica()
        NotificationCenter.default.post(name: TopicSyncStore.accountChangedNotification, object: self)
    }

    private func loadPersistedUbiquityToken() -> (NSCoding & NSCopying & NSObjectProtocol)? {
        guard let data = UserDefaults.standard.data(forKey: Self.ubiquityTokenDefaultsKey) else { return nil }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        // NSUbiquityIdentityToken is an opaque, undocumented concrete class, so we can't name it in
        // an allowed-classes list; secure coding has to be off for the read side.
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? (NSCoding & NSCopying & NSObjectProtocol)
    }

    private func persistUbiquityToken(_ token: (NSCoding & NSCopying & NSObjectProtocol)?) {
        guard let token else {
            // Signed out: store an empty marker so "we have looked before" stays distinguishable
            // from "first launch" only via the key's presence, which is all handleAccountChanged
            // needs (a nil-decoding archive reads back as nil).
            UserDefaults.standard.set(Data(), forKey: Self.ubiquityTokenDefaultsKey)
            return
        }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else {
            Log.w(Self.tag, "Could not archive the ubiquity identity token")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.ubiquityTokenDefaultsKey)
    }

    // MARK: - Store lifecycle

    private func loadStores() {
        container.loadPersistentStores { [weak self] _, error in
            if let error {
                Log.e(TopicSyncStore.tag, "Failed to load TopicSync store: \(error.localizedDescription)", error)
                self?.setStoreLoadedSuccessfully(false)
            } else {
                self?.setStoreLoadedSuccessfully(true)
            }
        }
    }

    private func setStoreLoadedSuccessfully(_ value: Bool) {
        stateLock.lock()
        storeLoadedSuccessfullyStorage = value
        stateLock.unlock()
    }

    /// Throws away this device's copy of the mirrored data after an iCloud account change, so the
    /// new account's records can import cleanly.
    ///
    /// This deliberately destroys and reloads the SQLite file instead of deleting the rows through
    /// the mirrored `viewContext`: `NSPersistentCloudKitContainer` exports context deletes as real
    /// CloudKit deletes, which would wipe the *previous* account's topic list out of that account's
    /// private database and propagate to all of its other devices. Destroying the store file is
    /// purely local — CloudKit never hears about it.
    private func clearLocalReplica() {
        guard !inMemory else { return }
        let coordinator = container.persistentStoreCoordinator
        guard let store = coordinator.persistentStores.first, let url = store.url else {
            Log.w(Self.tag, "No loaded TopicSync store to clear")
            return
        }
        context.performAndWait { context.reset() }
        setStoreLoadedSuccessfully(false)
        do {
            try coordinator.remove(store)
            try coordinator.destroyPersistentStore(at: url, type: .sqlite, options: nil)
        } catch {
            Log.e(Self.tag, "Failed to destroy the local TopicSync store: \(error.localizedDescription)", error)
        }
        loadStores()
    }
}
