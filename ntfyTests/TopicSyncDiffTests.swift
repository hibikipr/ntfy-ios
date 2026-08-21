import XCTest
@testable import ntfy

final class TopicSyncDiffTests: XCTestCase {
    func testRemoteOnlyReturnsItemsInSyncedButNotLocal() {
        let local = [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")]
        let synced = [
            TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts"),
            TopicIdentity(baseUrl: "https://ntfy.sh", topic: "backups")
        ]
        let result = TopicSyncDiff.remoteOnly(local: local, synced: synced)
        XCTAssertEqual(result, [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "backups")])
    }

    func testLocalOnlyReturnsItemsInLocalButNotSynced() {
        let local = [
            TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts"),
            TopicIdentity(baseUrl: "https://ntfy.sh", topic: "backups")
        ]
        let synced = [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")]
        let result = TopicSyncDiff.localOnly(local: local, synced: synced)
        XCTAssertEqual(result, [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "backups")])
    }

    func testIdenticalSetsProduceNoDifferences() {
        let identity = TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")
        XCTAssertTrue(TopicSyncDiff.remoteOnly(local: [identity], synced: [identity]).isEmpty)
        XCTAssertTrue(TopicSyncDiff.localOnly(local: [identity], synced: [identity]).isEmpty)
    }

    func testEmptyLocalTreatsEverySyncedItemAsRemoteOnly() {
        let synced = [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")]
        XCTAssertEqual(TopicSyncDiff.remoteOnly(local: [], synced: synced), synced)
        XCTAssertTrue(TopicSyncDiff.localOnly(local: [], synced: synced).isEmpty)
    }

    func testSameTopicDifferentServerAreNotEqual() {
        let local = [TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")]
        let synced = [TopicIdentity(baseUrl: "https://example.com", topic: "alerts")]
        XCTAssertEqual(TopicSyncDiff.remoteOnly(local: local, synced: synced), synced)
        XCTAssertEqual(TopicSyncDiff.localOnly(local: local, synced: synced), local)
    }
}
