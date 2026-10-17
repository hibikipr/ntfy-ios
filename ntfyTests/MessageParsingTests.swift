import XCTest
import UserNotifications
@testable import ntfy

final class MessageParsingTests: XCTestCase {

    // MARK: - Message JSON decoding

    func testDecodesMinimalMessage() throws {
        let json = """
        {"id":"abc123","time":1700000000,"event":"message","topic":"mytopic"}
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(Message.self, from: json)

        XCTAssertEqual(message.id, "abc123")
        XCTAssertEqual(message.time, 1700000000)
        XCTAssertEqual(message.event, "message")
        XCTAssertEqual(message.topic, "mytopic")
        XCTAssertNil(message.message)
        XCTAssertNil(message.title)
        XCTAssertNil(message.contentType)
    }

    func testDecodesFullMessageIncludingContentType() throws {
        let json = """
        {
            "id": "abc123",
            "time": 1700000000,
            "event": "message",
            "topic": "mytopic",
            "message": "**bold**",
            "title": "A title",
            "priority": 4,
            "tags": ["warning", "skull"],
            "click": "https://example.com",
            "poll_id": "poll123",
            "content_type": "text/markdown"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(Message.self, from: json)

        XCTAssertEqual(message.message, "**bold**")
        XCTAssertEqual(message.title, "A title")
        XCTAssertEqual(message.priority, 4)
        XCTAssertEqual(message.tags, ["warning", "skull"])
        XCTAssertEqual(message.click, "https://example.com")
        XCTAssertEqual(message.pollId, "poll123")
        XCTAssertEqual(message.contentType, "text/markdown")
        XCTAssertTrue(message.isMarkdown)
    }

    func testMissingRequiredFieldFailsToDecode() {
        let json = """
        {"id":"abc123","time":1700000000,"event":"message"}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(Message.self, from: json))
    }

    // MARK: - Markdown content-type detection

    func testIsMarkdownContentTypeRecognizesExactMatch() {
        XCTAssertTrue(Message.isMarkdownContentType("text/markdown"))
    }

    func testIsMarkdownContentTypeToleratesCharsetSuffix() {
        XCTAssertTrue(Message.isMarkdownContentType("text/markdown; charset=utf-8"))
    }

    func testIsMarkdownContentTypeIsCaseInsensitive() {
        XCTAssertTrue(Message.isMarkdownContentType("TEXT/MARKDOWN"))
    }

    func testIsMarkdownContentTypeRejectsPlainText() {
        XCTAssertFalse(Message.isMarkdownContentType("text/plain"))
    }

    func testIsMarkdownContentTypeRejectsNil() {
        XCTAssertFalse(Message.isMarkdownContentType(nil))
    }

    // MARK: - markdownToPlainText

    func testMarkdownToPlainTextStripsFormattingMarkers() {
        let plain = markdownToPlainText("**Bold**, *italic*, and `code`")
        XCTAssertEqual(plain, "Bold, italic, and code")
    }

    func testMarkdownToPlainTextStripsLinkSyntax() {
        let plain = markdownToPlainText("Check out [ntfy](https://ntfy.sh) today")
        XCTAssertEqual(plain, "Check out ntfy today")
    }

    func testMarkdownToPlainTextLeavesPlainTextUnchanged() {
        let plain = markdownToPlainText("Just a normal message with no markup")
        XCTAssertEqual(plain, "Just a normal message with no markup")
    }

    // MARK: - toUserInfo / from(userInfo:) round-trip

    func testUserInfoRoundTripPreservesContentType() {
        let original = Message(
            id: "abc123",
            time: 1700000000,
            event: "message",
            topic: "mytopic",
            message: "**bold**",
            title: "A title",
            priority: 4,
            tags: ["warning"],
            click: "https://example.com",
            pollId: "poll123",
            contentType: "text/markdown"
        )

        let userInfo = original.toUserInfo()
        let roundTripped = Message.from(userInfo: userInfo)

        XCTAssertEqual(roundTripped?.id, original.id)
        XCTAssertEqual(roundTripped?.time, original.time)
        XCTAssertEqual(roundTripped?.message, original.message)
        XCTAssertEqual(roundTripped?.title, original.title)
        XCTAssertEqual(roundTripped?.priority, original.priority)
        XCTAssertEqual(roundTripped?.contentType, original.contentType)
        XCTAssertEqual(roundTripped?.pollId, original.pollId)
        XCTAssertEqual(roundTripped?.isMarkdown, true)
    }

    func testUserInfoRoundTripWithNoContentTypeIsNotMarkdown() {
        // toUserInfo() encodes a nil contentType as "" (userInfo dictionaries can't hold true
        // nil, same as click/pollId elsewhere), so it round-trips as an empty string rather than
        // nil — but isMarkdown must still correctly read that as "not Markdown".
        let original = Message(id: "abc123", time: 1700000000, event: "message", topic: "mytopic")

        let userInfo = original.toUserInfo()
        let roundTripped = Message.from(userInfo: userInfo)

        XCTAssertEqual(roundTripped?.contentType, "")
        XCTAssertEqual(roundTripped?.isMarkdown, false)
    }

    func testFromUserInfoReturnsNilWhenRequiredFieldsMissing() {
        let incomplete: [AnyHashable: Any] = ["id": "abc123", "event": "message"]
        XCTAssertNil(Message.from(userInfo: incomplete))
    }

    func testUserInfoRoundTripPreservesAttachment() {
        let attachment = MessageAttachment(name: "photo.jpg", type: "image/jpeg", size: 1024, expires: nil, url: "https://example.com/photo.jpg")
        let original = Message(id: "abc123", time: 1700000000, event: "message", topic: "mytopic", attachment: attachment)

        let userInfo = original.toUserInfo()
        let roundTripped = Message.from(userInfo: userInfo)

        XCTAssertEqual(roundTripped?.attachment?.name, "photo.jpg")
        XCTAssertEqual(roundTripped?.attachment?.type, "image/jpeg")
        XCTAssertEqual(roundTripped?.attachment?.size, 1024)
        XCTAssertEqual(roundTripped?.attachment?.url, "https://example.com/photo.jpg")
    }

    // MARK: - MessageAttachment

    func testIsImageAttachmentDetectsByMimeType() {
        let attachment = MessageAttachment(name: "file", type: "image/png", size: nil, expires: nil, url: "https://example.com/file")
        XCTAssertTrue(attachment.isImageAttachment())
    }

    func testIsImageAttachmentDetectsByFileExtension() {
        let attachment = MessageAttachment(name: "file", type: nil, size: nil, expires: nil, url: "https://example.com/photo.PNG")
        XCTAssertTrue(attachment.isImageAttachment())
    }

    func testIsImageAttachmentRejectsNonImage() {
        let attachment = MessageAttachment(name: "file", type: "application/pdf", size: nil, expires: nil, url: "https://example.com/doc.pdf")
        XCTAssertFalse(attachment.isImageAttachment())
    }

    func testAttachmentIsExpired() {
        let expired = MessageAttachment(name: "file", type: nil, size: nil, expires: 1000, url: "https://example.com/file")
        XCTAssertTrue(expired.isExpired(referenceDate: Date(timeIntervalSince1970: 2000)))

        let notExpired = MessageAttachment(name: "file", type: nil, size: nil, expires: 3000, url: "https://example.com/file")
        XCTAssertFalse(notExpired.isExpired(referenceDate: Date(timeIntervalSince1970: 2000)))
    }

    // MARK: - BasicUser

    func testBasicUserToHeaderEncodesBase64() {
        let user = BasicUser(username: "phil", password: "phil123")
        XCTAssertEqual(user.toHeader(), "Basic cGhpbDpwaGlsMTIz")
    }
}

final class ReplayTombstonesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ReplayTombstonesTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRemembersAddedIDs() {
        let tombstones = ReplayTombstones(defaults: defaults)
        tombstones.add(["a": 1_000, "b": 1_000], now: 1_000)

        XCTAssertTrue(tombstones.contains("a"))
        XCTAssertTrue(tombstones.contains("b"))
        XCTAssertFalse(tombstones.contains("c"))
    }

    func testPersistsAcrossInstances() {
        ReplayTombstones(defaults: defaults).add(["a": 1_000], now: 1_000)

        XCTAssertTrue(ReplayTombstones(defaults: defaults).contains("a"))
    }

    func testDropsEntriesOlderThanMaxAge() {
        let tombstones = ReplayTombstones(defaults: defaults)
        tombstones.add(["old": 0], now: 0)
        tombstones.add(["new": ReplayTombstones.maxAge + 1], now: ReplayTombstones.maxAge + 1)

        XCTAssertFalse(tombstones.contains("old"))
        XCTAssertTrue(tombstones.contains("new"))
    }

    func testKeepsOnlyNewestMaxEntries() {
        let tombstones = ReplayTombstones(defaults: defaults)
        let count = ReplayTombstones.maxEntries + 10
        let entries = Dictionary(uniqueKeysWithValues: (0..<count).map { ("id\($0)", Int64($0)) })
        tombstones.add(entries, now: Int64(count))

        XCTAssertFalse(tombstones.contains("id0"))
        XCTAssertFalse(tombstones.contains("id9"))
        XCTAssertTrue(tombstones.contains("id10"))
        XCTAssertTrue(tombstones.contains("id\(count - 1)"))
    }
}

final class SequenceIdTests: XCTestCase {
    private let baseUrl = "https://ntfy.example.com"
    // Recent, since `ReplayTombstones` forgets messages older than a week
    private let now = Int64(Date().timeIntervalSince1970)
    private var store: Store!
    private var subscription: Subscription!

    override func setUp() {
        super.setUp()
        store = Store(inMemory: true)
        subscription = store.saveSubscription(baseUrl: baseUrl, topic: "mytopic")
    }

    override func tearDown() {
        subscription = nil
        store = nil
        super.tearDown()
    }

    // Random IDs, since `ReplayTombstones` lives in the shared defaults and outlives a test
    private func message(_ event: String = "message", sequenceId: String? = nil, text: String? = nil, time: Int64? = nil) -> Message {
        Message(
            id: UUID().uuidString,
            time: time ?? now,
            event: event,
            topic: "mytopic",
            message: text ?? (event == "message" ? "text" : nil),
            sequenceId: sequenceId
        )
    }

    private func stored() -> [ntfy.Notification] {
        var notifications: [ntfy.Notification] = []
        store.context.performAndWait {
            let request = ntfy.Notification.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: true)]
            notifications = (try? store.context.fetch(request)) ?? []
        }
        return notifications
    }

    // MARK: - Message

    func testDecodesSequenceId() throws {
        let json = """
        {"id":"abc123","time":1700000000,"event":"message_delete","topic":"mytopic","sequence_id":"seq1"}
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(Message.self, from: json)

        XCTAssertEqual(message.sequenceId, "seq1")
        XCTAssertEqual(message.effectiveSequenceId, "seq1")
    }

    func testEffectiveSequenceIdFallsBackToMessageId() {
        XCTAssertEqual(Message(id: "abc", time: 0, event: "message", topic: "t").effectiveSequenceId, "abc")
        XCTAssertEqual(Message(id: "abc", time: 0, event: "message", topic: "t", sequenceId: "").effectiveSequenceId, "abc")
    }

    func testSequenceIdRoundTripsThroughUserInfo() {
        let original = Message(id: "abc", time: 1, event: "message", topic: "t", sequenceId: "seq1")
        XCTAssertEqual(Message.from(userInfo: original.toUserInfo())?.sequenceId, "seq1")

        // The server sends an empty sequence_id for messages published without one
        let withoutSequence = Message(id: "abc", time: 1, event: "message", topic: "t")
        XCTAssertNil(Message.from(userInfo: withoutSequence.toUserInfo())?.sequenceId)
    }

    func testMatchesDeliveredNotificationsBySequenceAndTopic() {
        var userInfo = Message(id: "abc", time: 1, event: "message", topic: "mytopic", sequenceId: "seq1").toUserInfo()
        userInfo["base_url"] = baseUrl + "/"

        XCTAssertTrue(UNUserNotificationCenter.isDeliveredNotification(userInfo: userInfo, of: ["seq1"], baseUrl: baseUrl, topic: "mytopic"))
        XCTAssertFalse(UNUserNotificationCenter.isDeliveredNotification(userInfo: userInfo, of: ["abc"], baseUrl: baseUrl, topic: "mytopic"))
        XCTAssertFalse(UNUserNotificationCenter.isDeliveredNotification(userInfo: userInfo, of: ["seq1"], baseUrl: baseUrl, topic: "other"))
        XCTAssertFalse(UNUserNotificationCenter.isDeliveredNotification(userInfo: userInfo, of: ["seq1"], baseUrl: "https://ntfy.sh", topic: "mytopic"))
    }

    // MARK: - Store

    func testStoresSequenceId() {
        let first = message(sequenceId: "seq1")
        let second = message()
        store.save(notificationsFromMessages: [first, second], withSubscription: subscription)

        XCTAssertEqual(Set(stored().compactMap(\.sequenceId)), ["seq1", second.id])
    }

    func testUpdateReplacesNotificationOfSameSequence() {
        store.save(notificationsFromMessages: [message(sequenceId: "seq1", text: "Downloading")], withSubscription: subscription)
        let other = message(sequenceId: "other", text: "Other")
        store.save(notificationsFromMessages: [other], withSubscription: subscription)

        let update = message(sequenceId: "seq1", text: "Done", time: now + 1)
        let saved = store.save(notificationsFromMessages: [update], withSubscription: subscription)

        XCTAssertEqual(saved.shown.map(\.id), [update.id])
        XCTAssertEqual(saved.outdatedSequenceIds, ["seq1"])
        XCTAssertEqual(Set(stored().map(\.message)), ["Done", "Other"])
    }

    func testUpdateWithMessageIdAsSequenceIdReplacesOriginal() {
        let original = message()
        store.save(notificationsFromMessages: [original], withSubscription: subscription)

        store.save(notificationsFromMessages: [message(sequenceId: original.id, text: "Updated", time: now + 1)], withSubscription: subscription)

        XCTAssertEqual(stored().map(\.message), ["Updated"])
    }

    func testUpdateReplacesNotificationStoredWithoutSequenceId() {
        // Notifications stored before the sequenceId attribute existed have none
        let original = message()
        store.save(notificationsFromMessages: [original], withSubscription: subscription)
        store.context.performAndWait {
            stored().first?.sequenceId = nil
            try? store.context.save()
        }

        store.save(notificationsFromMessages: [message(sequenceId: original.id, text: "Updated", time: now + 1)], withSubscription: subscription)

        XCTAssertEqual(stored().map(\.message), ["Updated"])
    }

    func testSkipsUpdateOlderThanStoredVersion() {
        store.save(notificationsFromMessages: [message(sequenceId: "seq1", text: "Done", time: now + 1)], withSubscription: subscription)

        let saved = store.save(notificationsFromMessages: [message(sequenceId: "seq1", text: "Downloading")], withSubscription: subscription)

        XCTAssertTrue(saved.shown.isEmpty)
        XCTAssertEqual(stored().map(\.message), ["Done"])
    }

    func testPollWithSeveralVersionsKeepsLatest() {
        let saved = store.save(notificationsFromMessages: [
            message(sequenceId: "seq1", text: "Downloading"),
            message(sequenceId: "seq1", text: "Done", time: now + 1),
        ], withSubscription: subscription)

        XCTAssertEqual(saved.shown.map(\.message), ["Done"])
        XCTAssertEqual(stored().map(\.message), ["Done"])
    }

    func testDeleteRemovesNotificationsOfSequence() {
        let kept = message(sequenceId: "other")
        store.save(notificationsFromMessages: [message(sequenceId: "seq1"), kept], withSubscription: subscription)

        let saved = store.save(notificationsFromMessages: [message("message_delete", sequenceId: "seq1", time: now + 1)], withSubscription: subscription)

        XCTAssertTrue(saved.shown.isEmpty)
        XCTAssertEqual(saved.dismissedSequenceIds, ["seq1"])
        XCTAssertEqual(stored().map(\.id), [kept.id])
    }

    func testDeleteInSamePollDropsMessage() {
        let delete = message("message_delete", sequenceId: "seq1", time: now + 1)
        let saved = store.save(notificationsFromMessages: [message(sequenceId: "seq1"), delete], withSubscription: subscription)

        XCTAssertTrue(saved.shown.isEmpty)
        XCTAssertTrue(stored().isEmpty)
        XCTAssertEqual(subscription.lastNotificationId, delete.id)
    }

    func testClearMarksNotificationsOfSequenceRead() {
        store.save(notificationsFromMessages: [message(sequenceId: "seq1"), message(sequenceId: "other")], withSubscription: subscription)

        let saved = store.save(notificationsFromMessages: [message("message_clear", sequenceId: "seq1", time: now + 1)], withSubscription: subscription)

        XCTAssertEqual(saved.dismissedSequenceIds, ["seq1"])
        XCTAssertEqual(stored().count, 2)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: stored().map { ($0.sequenceId!, $0.isRead) }), ["seq1": true, "other": false])
    }

    func testReplayedClearDoesNotMarkNewerVersionRead() {
        // Since ntfy v2.31, a `since=<id>` poll returns the newest second again
        let clear = message("message_clear", sequenceId: "seq1")
        let update = message(sequenceId: "seq1", text: "Again")
        store.save(notificationsFromMessages: [message(sequenceId: "seq1"), clear, update], withSubscription: subscription)

        store.save(notificationsFromMessages: [clear, update], withSubscription: subscription)

        XCTAssertEqual(stored().map(\.message), ["Again"])
        XCTAssertEqual(stored().map(\.isRead), [false])
    }

    func testReplayedOldVersionDoesNotReplaceUpdate() {
        let first = message(sequenceId: "seq1", text: "Downloading")
        let update = message(sequenceId: "seq1", text: "Done")
        store.save(notificationsFromMessages: [first], withSubscription: subscription)
        store.save(notificationsFromMessages: [update], withSubscription: subscription)

        store.save(notificationsFromMessages: [first, update], withSubscription: subscription)

        XCTAssertEqual(stored().map(\.message), ["Done"])
    }

    func testIgnoresPollRequests() {
        let saved = store.save(notificationsFromMessages: [message("poll_request")], withSubscription: subscription)

        XCTAssertTrue(saved.shown.isEmpty)
        XCTAssertTrue(stored().isEmpty)
    }

    func testSaveForUnknownTopicReturnsNil() {
        XCTAssertNil(store.save(notificationFromMessage: message(), baseUrl: baseUrl, topic: "unknown"))
        XCTAssertEqual(store.save(notificationFromMessage: message(), baseUrl: baseUrl, topic: "mytopic")?.shown.count, 1)
    }
}
