import Foundation
import FirebaseCore
import FirebaseMessaging

/// Manager to combine persisting a subscription to the data store and subscribing to Firebase.
/// This is to centralize the logic in one place.
struct SubscriptionManager {
    private let tag = "SubscriptionManager"
    var store: Store
    
    func subscribe(baseUrl: String, topic: String) {
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        let firebaseTopicName = firebaseTopic(baseUrl: normalizedBaseUrl, topic: topic)
        if FirebaseApp.app() != nil {
            Log.d(tag, "Subscribing to \(topicUrl(baseUrl: normalizedBaseUrl, topic: topic))")
            Messaging.messaging().subscribe(toTopic: firebaseTopicName) { error in
                if let error {
                    Log.e(tag, "Firebase subscribe failed for \(firebaseTopicName)", error)
                } else {
                    Log.d(tag, "Firebase subscribe succeeded for \(firebaseTopicName)")
                }
            }
        }
        let subscription = store.saveSubscription(baseUrl: normalizedBaseUrl, topic: topic)
        Task {
            await poll(subscription, notifyOnNewMessages: false)
        }
    }
    
    func unsubscribe(_ subscription: Subscription) {
        Log.d(tag, "Unsubscribing from \(subscription.urlString())")
        DispatchQueue.main.async {
            if let baseUrl = subscription.baseUrl, let topic = subscription.topic, FirebaseApp.app() != nil {
                let firebaseTopicName = firebaseTopic(baseUrl: baseUrl, topic: topic)
                Messaging.messaging().unsubscribe(fromTopic: firebaseTopicName) { error in
                    if let error {
                        Log.e(tag, "Firebase unsubscribe failed for \(firebaseTopicName)", error)
                    } else {
                        Log.d(tag, "Firebase unsubscribe succeeded for \(firebaseTopicName)")
                    }
                }
            }
            store.delete(subscription: subscription)
        }
    }
    
    @discardableResult
    @MainActor
    func poll(_ subscription: Subscription, notifyOnNewMessages: Bool = true) async -> [Message] {
        // This is a bit of a hack but it prevents us from polling dead subscriptions
        guard subscription.baseUrl != nil else {
            Log.d(tag, "Attempting to poll dead subscription failed")
            return []
        }

        let user = store.getUser(baseUrl: subscription.baseUrl!)?.toBasicUser()
        Log.d(tag, "Polling from \(subscription.urlString()) with user \(user != nil ? "<redacted>" : "anonymous")")
        let messages: [Message]
        do {
            messages = try await ApiService.shared.poll(subscription: subscription, user: user)
        } catch {
            Log.e(tag, "Polling failed", error)
            return []
        }
        Log.d(tag, "Polling success, \(messages.count) new message(s)", messages)
        guard !messages.isEmpty else {
            return []
        }
        let newMessages = store.save(notificationsFromMessages: messages, withSubscription: subscription)
        guard notifyOnNewMessages, !newMessages.isEmpty, let baseUrl = subscription.baseUrl else {
            return newMessages
        }
        await withCheckedContinuation { continuation in
            LocalNotificationPoster.showSequentially(baseUrl: baseUrl, messages: newMessages) {
                continuation.resume()
            }
        }
        return newMessages
    }
}
