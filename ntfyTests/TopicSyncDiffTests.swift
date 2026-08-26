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

    // MARK: - metadataChanged

    func testMetadataChangedDetectsRenameOnATopicPresentOnBothSides() {
        // The bug this guards against: a topic already synced on both devices, renamed on
        // another device, never showed the new name — remoteOnly/localOnly are identity-only,
        // so an already-shared topic falls into neither list no matter how its metadata diverges.
        let identity = TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")
        let local = [TopicMetadata(identity: identity, customDisplayName: "Old Name", icon: nil)]
        let synced = [TopicMetadata(identity: identity, customDisplayName: "New Name", icon: nil)]
        XCTAssertEqual(TopicSyncDiff.metadataChanged(local: local, synced: synced), [identity])
    }

    func testMetadataChangedDetectsIconChange() {
        let identity = TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")
        let local = [TopicMetadata(identity: identity, customDisplayName: nil, icon: "bell")]
        let synced = [TopicMetadata(identity: identity, customDisplayName: nil, icon: "star")]
        XCTAssertEqual(TopicSyncDiff.metadataChanged(local: local, synced: synced), [identity])
    }

    func testMetadataChangedIgnoresIdenticalMetadata() {
        let identity = TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")
        let local = [TopicMetadata(identity: identity, customDisplayName: "Same", icon: "bell")]
        let synced = [TopicMetadata(identity: identity, customDisplayName: "Same", icon: "bell")]
        XCTAssertTrue(TopicSyncDiff.metadataChanged(local: local, synced: synced).isEmpty)
    }

    func testMetadataChangedIgnoresTopicsMissingLocally() {
        // remoteOnly's job, not metadataChanged's — a topic that doesn't exist locally at all
        // isn't a "change", it's a subscribe.
        let identity = TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")
        let synced = [TopicMetadata(identity: identity, customDisplayName: "New Name", icon: nil)]
        XCTAssertTrue(TopicSyncDiff.metadataChanged(local: [], synced: synced).isEmpty)
    }

    func testMetadataChangedTreatsNilAndSetNameAsDifferent() {
        let identity = TopicIdentity(baseUrl: "https://ntfy.sh", topic: "alerts")
        let local = [TopicMetadata(identity: identity, customDisplayName: nil, icon: nil)]
        let synced = [TopicMetadata(identity: identity, customDisplayName: "New Name", icon: nil)]
        XCTAssertEqual(TopicSyncDiff.metadataChanged(local: local, synced: synced), [identity])
    }
}
