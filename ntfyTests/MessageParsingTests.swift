import XCTest
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
