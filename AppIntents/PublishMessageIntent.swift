import AppIntents
import Foundation

struct PublishMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Publish Message"
    static var description = IntentDescription("Publishes a message to one of your subscribed ntfy topics.")

    @Parameter(title: "Topic")
    var topic: TopicEntity

    @Parameter(title: "Message")
    var message: String

    @Parameter(title: "Title", default: nil)
    var messageTitle: String?

    func perform() async throws -> some IntentResult {
        let (subscription, user) = await MainActor.run {
            (
                Store.shared.getSubscription(baseUrl: topic.baseUrl, topic: topic.topic),
                Store.shared.getBasicUser(baseUrl: topic.baseUrl)
            )
        }
        guard let subscription else {
            throw PublishMessageIntentError.topicNoLongerSubscribed
        }
        try await ApiService.shared.publish(
            subscription: subscription,
            user: user,
            message: message,
            title: messageTitle ?? ""
        )
        return .result()
    }
}

enum PublishMessageIntentError: LocalizedError {
    case topicNoLongerSubscribed

    var errorDescription: String? {
        switch self {
        case .topicNoLongerSubscribed:
            return "This topic is no longer subscribed."
        }
    }
}
