import UserNotifications
import CoreData
import CryptoKit

/// This app extension is responsible for persisting the incoming notification to the data store (Core Data). It will eventually be the entity that
/// fetches notification content from selfhosted servers (when a "poll request" is received). This is not implemented yet.
///
/// Note that the app extension does not run as part of the main app, so log messages are not printed in the main Xcode window. To debug,
/// select Debug -> Attach to Process by PID or Name, and select the extension. Don't forget to set a breakpoint, or you're not gonna have a good time.
class NotificationService: UNNotificationServiceExtension {
    private let tag = "NotificationService"
    private var store: Store?
    
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.store = Store.shared
        self.contentHandler = contentHandler
        self.bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        if let bestAttemptContent = bestAttemptContent {
            let userInfo = bestAttemptContent.userInfo
            guard let message = Message.from(userInfo: userInfo) else {
                Log.w(tag, "Message cannot be parsed from userInfo", userInfo)
                contentHandler(request.content)
                return
            }
            Log.d(
                tag,
                "\(#function) event=\(message.event), topic=\(message.topic), pollId=\(message.pollId ?? "<nil>"), baseUrl=\(userInfo["base_url"] as? String ?? "<nil>")"
            )
            switch message.event {
            case "poll_request":
                handlePollRequest(request, bestAttemptContent, message, contentHandler)
            case "message", "message_delete", "message_clear":
                let baseUrl = userInfo["base_url"]  as? String ?? Config.appBaseUrl // messages only come for the main server
                handleMessage(request, bestAttemptContent, baseUrl, message, contentHandler)
            default:
                Log.w(tag, "Irrelevant message received", message)
                contentHandler(request.content)
            }
        }
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content,
        // otherwise the original push payload will be used.

        Log.w(tag, "\(#function): delivering best attempt content")
        if let contentHandler = contentHandler, let bestAttemptContent =  bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
    
    private func handleMessage(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ baseUrl: String, _ message: Message, _ contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Save notification first so attachment downloads can update persistent state.
        guard let saved = store?.save(notificationFromMessage: message, baseUrl: baseUrl, topic: message.topic) else {
            Log.w(tag, "Cannot save message for \(topicUrl(baseUrl: baseUrl, topic: message.topic)), unknown subscription or failed")
            contentHandler(request.content)
            return
        }
        // Remove the notifications this one deletes, clears or replaces (see `Message.sequenceId`)
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            baseUrl: baseUrl,
            topic: message.topic,
            sequenceIds: saved.outdatedSequenceIds
        ) {
            guard saved.shown.contains(where: { $0.id == message.id }) else {
                // A delete or clear event, a stale update, or a message that is stored already.
                // Without the filtering entitlement the alert can't be dropped, but iOS doesn't
                // show a notification without title and body.
                Log.d(self.tag, "Suppressing alert for \(message.event) \(message.id)")
                let empty = UNMutableNotificationContent()
                empty.badge = NSNumber(value: self.store?.unreadNotificationCount() ?? 0)
                contentHandler(empty)
                return
            }
            content.badge = NSNumber(value: self.store?.unreadNotificationCount() ?? 0)
            let user = self.store?.getCredentials(baseUrl: baseUrl)
            content.modify(message: message, baseUrl: baseUrl)
            content.attachImageIfNeeded(message: message, user: user) {
                content.withIconIfNeeded(message: message, completionHandler: contentHandler)
            }
        }
    }
    
    private func handlePollRequest(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ pollRequest: Message, _ contentHandler: @escaping (UNNotificationContent) -> Void) {
        let pollId = pollRequest.pollId ?? pollRequest.id
        let preferredBaseUrl = bestAttemptContent?.userInfo["base_url"] as? String
        guard let subscription = store?.findSubscriptionMatch(
                forPollRequestTopic: pollRequest.topic,
                preferredBaseUrl: preferredBaseUrl
            )
        else {
            Log.w(tag, "Cannot find subscription for poll request topic=\(pollRequest.topic), pollId=\(pollRequest.pollId ?? "<nil>")")
            contentHandler(request.content)
            return
        }
        
        // Poll original server
        let user = store?.getCredentials(baseUrl: subscription.baseUrl)
        // The extension only needs contentHandler to be called from the async callback
        Task {
            let message: Message
            do {
                message = try await ApiService.shared.poll(baseUrl: subscription.baseUrl, topic: subscription.topic, messageId: pollId, user: user)
            } catch {
                Log.w(self.tag, "Error fetching poll request message topic=\(pollRequest.topic), pollId=\(pollId), subscription=\(topicUrl(baseUrl: subscription.baseUrl, topic: subscription.topic))", error)
                contentHandler(request.content)
                return
            }
            self.handleMessage(request, content, subscription.baseUrl, message, contentHandler)
        }
    }
}
