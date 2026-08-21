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
}
