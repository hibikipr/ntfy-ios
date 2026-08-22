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

    /// A tie has no tiebreaker that agrees across devices (`recordName` is identical for true
    /// duplicates), so if a tie could pick a loser, two devices could each delete a different copy
    /// and between them destroy the topic — after which reconciliation unsubscribes it locally,
    /// taking its notification history with it. A tied group must therefore lose nothing.
    func testAllSyncedTopicsKeepsBothDuplicatesWhenLastModifiedTies() {
        let store = TopicSyncStore(inMemory: true)
        let tie = Date(timeIntervalSince1970: 1_000)
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "A", modified: tie)
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "B", modified: tie)

        // Reconciliation still sees the topic exactly once...
        XCTAssertEqual(store.allSyncedTopics().count, 1)
        XCTAssertEqual(store.allSyncedTopics().first?.topic, "alerts")
        // ...but neither row was deleted, so the topic cannot vanish if another device makes the
        // opposite arbitrary choice.
        XCTAssertEqual(rawRowCount(in: store), 2)
    }

    /// `lastModified` is optional for CloudKit compatibility, so two partially-imported records can
    /// both arrive without one and tie on the `.distantPast` fallback.
    func testAllSyncedTopicsKeepsBothDuplicatesWhenLastModifiedIsMissingOnBoth() {
        let store = TopicSyncStore(inMemory: true)
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "A", modified: nil)
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "B", modified: nil)

        XCTAssertEqual(store.allSyncedTopics().count, 1)
        XCTAssertEqual(store.allSyncedTopics().first?.topic, "alerts")
        XCTAssertEqual(rawRowCount(in: store), 2)
    }

    /// A row that is *strictly* older than the newest is an unambiguous loser on every device, so it
    /// is still collapsed even when the newest value itself is tied.
    func testAllSyncedTopicsDeletesStrictlyOlderDuplicatesButKeepsTiedNewestOnes() {
        let store = TopicSyncStore(inMemory: true)
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "Old", modified: Date(timeIntervalSince1970: 1_000))
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "New1", modified: Date(timeIntervalSince1970: 2_000))
        insertRaw(into: store, baseUrl: "https://ntfy.sh", topic: "alerts", displayName: "New2", modified: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(store.allSyncedTopics().count, 1)
        XCTAssertEqual(rawRowCount(in: store), 2)
        XCTAssertEqual(store.allSyncedTopics().first?.customDisplayName?.hasPrefix("New"), true)
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

    // MARK: - Launch-time account comparison

    /// First launch after install: nothing has been recorded, so this must behave like a normal
    /// bootstrap (upload this device's own topics), not like an account change.
    func testLaunchIsNotOnANewAccountWhenNothingWasEverBootstrapped() {
        XCTAssertFalse(TopicSyncStore.launchIsOnANewAccount(
            lastBootstrapped: nil,
            hasBootstrapRecord: false,
            current: NSString("account-A")
        ))
    }

    func testLaunchIsNotOnANewAccountWhenTheTokenIsUnchanged() {
        XCTAssertFalse(TopicSyncStore.launchIsOnANewAccount(
            lastBootstrapped: NSString("account-A"),
            hasBootstrapRecord: true,
            current: NSString("account-A")
        ))
    }

    /// The switched-accounts-while-not-running case: no CKAccountChanged ever fired, and only this
    /// comparison stops the launch from uploading the previous account owner's subscriptions.
    func testLaunchIsOnANewAccountWhenTheTokenChangedBetweenLaunches() {
        XCTAssertTrue(TopicSyncStore.launchIsOnANewAccount(
            lastBootstrapped: NSString("account-A"),
            hasBootstrapRecord: true,
            current: NSString("account-B")
        ))
    }

    func testLaunchIsOnANewAccountWhenSigningInAfterBootstrappingWhileSignedOut() {
        XCTAssertTrue(TopicSyncStore.launchIsOnANewAccount(
            lastBootstrapped: nil,
            hasBootstrapRecord: true,
            current: NSString("account-A")
        ))
    }

    func testLaunchIsOnANewAccountWhenSignedOutAfterBootstrappingWithAnAccount() {
        XCTAssertTrue(TopicSyncStore.launchIsOnANewAccount(
            lastBootstrapped: NSString("account-A"),
            hasBootstrapRecord: true,
            current: nil
        ))
    }

    /// A device that has only ever run without iCloud must keep bootstrapping normally.
    func testLaunchIsNotOnANewAccountWhenStillSignedOut() {
        XCTAssertFalse(TopicSyncStore.launchIsOnANewAccount(
            lastBootstrapped: nil,
            hasBootstrapRecord: true,
            current: nil
        ))
    }

    // MARK: - Helpers

    /// Counts rows without going through `allSyncedTopics()`, so a test can tell "filtered out of
    /// the result" apart from "deleted from the store".
    private func rawRowCount(in store: TopicSyncStore) -> Int {
        var count = 0
        store.context.performAndWait {
            count = (try? store.context.count(for: SyncedTopic.fetchRequest())) ?? -1
        }
        return count
    }

    /// Inserts a row directly, bypassing `upsert`, to simulate what CloudKit mirroring does when
    /// it imports a record created on another device.
    private func insertRaw(into store: TopicSyncStore, baseUrl: String?, topic: String?, displayName: String?, modified: Date?) {
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
