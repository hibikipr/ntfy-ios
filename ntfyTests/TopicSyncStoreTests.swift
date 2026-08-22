import XCTest
@testable import ntfy

final class TopicSyncStoreTests: XCTestCase {
    func testUpsertThenFetchReturnsTheSameTopic() {
        let store = TopicSyncStore(inMemory: true)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "alerts", customDisplayName: "Alerts", icon: "🔔")

        let topics = store.allSyncedTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.baseUrl, "https://ntfy.sh")
        XCTAssertEqual(topics.first?.topic, "alerts")
        XCTAssertEqual(topics.first?.customDisplayName, "Alerts")
        XCTAssertEqual(topics.first?.icon, "🔔")
    }

    func testUpsertTwiceForSameTopicUpdatesInPlaceInsteadOfDuplicating() {
        let store = TopicSyncStore(inMemory: true)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "alerts", customDisplayName: "Alerts", icon: nil)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "alerts", customDisplayName: "Renamed", icon: "🔔")

        let topics = store.allSyncedTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.customDisplayName, "Renamed")
        XCTAssertEqual(topics.first?.icon, "🔔")
    }

    func testRemoveDeletesTheMatchingTopicOnly() {
        let store = TopicSyncStore(inMemory: true)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "alerts", customDisplayName: nil, icon: nil)
        store.upsert(baseUrl: "https://ntfy.sh", topic: "backups", customDisplayName: nil, icon: nil)

        store.remove(baseUrl: "https://ntfy.sh", topic: "alerts")

        let topics = store.allSyncedTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.topic, "backups")
    }

    func testRemoveOfNonexistentTopicDoesNothing() {
        let store = TopicSyncStore(inMemory: true)
        store.remove(baseUrl: "https://ntfy.sh", topic: "does-not-exist")
        XCTAssertTrue(store.allSyncedTopics().isEmpty)
    }

    func testStoreReportsSuccessfulLoad() {
        let store = TopicSyncStore(inMemory: true)
        XCTAssertTrue(store.storeLoadedSuccessfully)
    }

    /// `recordName` does not determine the mirrored object's CKRecord.ID, so two devices that
    /// create the same topic offline each produce their own CloudKit record and both mirror down
    /// here. `allSyncedTopics()` has to collapse them.
    func testAllSyncedTopicsCollapsesDuplicatesKeepingTheNewest() {
        let store = TopicSyncStore(inMemory: true)
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "Older", modified: Date(timeIntervalSince1970: 1_000))
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "Newer", modified: Date(timeIntervalSince1970: 2_000))

        let topics = store.allSyncedTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.customDisplayName, "Newer")
        // The loser must actually be deleted, not just filtered out of this one result.
        XCTAssertEqual(store.allSyncedTopics().count, 1)
    }

    func testAllSyncedTopicsKeepsDistinctTopicsAndServers() {
        let store = TopicSyncStore(inMemory: true)
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "A", modified: Date(timeIntervalSince1970: 1_000))
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "backups", displayName: "B", modified: Date(timeIntervalSince1970: 1_000))
        insertRaw(into: store, baseUrl: "https://example.com", topic: "alerts", displayName: "C", modified: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(store.allSyncedTopics().count, 3)
    }

    func testAllSyncedTopicsCollapsesMoreThanTwoDuplicates() {
        let store = TopicSyncStore(inMemory: true)
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "One", modified: Date(timeIntervalSince1970: 1_000))
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "Three", modified: Date(timeIntervalSince1970: 3_000))
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "Two", modified: Date(timeIntervalSince1970: 2_000))

        let topics = store.allSyncedTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.customDisplayName, "Three")
    }

    func testAllSyncedTopicsIgnoresRowsWithoutAnIdentity() {
        let store = TopicSyncStore(inMemory: true)
        insertRaw(into: store, baseUrl: nil, topic: nil, displayName: "Broken", modified: Date(timeIntervalSince1970: 1_000))
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "Good", modified: Date(timeIntervalSince1970: 1_000))

        let topics = store.allSyncedTopics()
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.topic, "alerts")
    }

    /// Inserts a row directly, bypassing `upsert`, to simulate what CloudKit mirroring does when
    /// it imports a record created on another device.
    private func insertRaw(into store: TopicSyncStore, baseUrl: String?, topic: String?, displayName: String?, modified: Date) {
        store.context.performAndWait {
            let syncedTopic = SyncedTopic(context: store.context)
            if let baseUrl, let topic {
                syncedTopic.recordName = "\(baseUrl)|\(topic)"
            }
            syncedTopic.baseUrl = baseUrl
            syncedTopic.topic = topic
            syncedTopic.customDisplayName = displayName
            syncedTopic.lastModified = modified
            try? store.context.save()
        }
    }
}
