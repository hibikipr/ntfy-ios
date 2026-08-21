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

    private static let containerIdentifier = "iCloud.com.victormanuel.ntfy" // must match Task 3's container

    private let container: NSPersistentCloudKitContainer
    var context: NSManagedObjectContext { container.viewContext }
    private var cancellables: Set<AnyCancellable> = []

    init(inMemory: Bool = false) {
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

        container.loadPersistentStores { _, error in
            if let error {
                Log.e(TopicSyncStore.tag, "Failed to load TopicSync store: \(error.localizedDescription)", error)
            }
        }
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)

        guard !inMemory else { return }
        NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .sink { [weak self] _ in
                guard let self else { return }
                self.context.perform { self.context.refreshAllObjects() }
                NotificationCenter.default.post(name: TopicSyncStore.didChangeNotification, object: self)
            }
            .store(in: &cancellables)
    }

    func allSyncedTopics() -> [SyncedTopic] {
        let request = SyncedTopic.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
        return (try? context.fetch(request)) ?? []
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
}
