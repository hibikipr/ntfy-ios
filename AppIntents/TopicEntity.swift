import AppIntents

/// A Shortcuts-facing representation of a subscribed topic. `id` is `"\(baseUrl)|\(topic)"`,
/// matching the existing `SyncedTopic.recordName` convention used elsewhere in this codebase —
/// both exist to give the same topic a stable, deterministic identifier regardless of which
/// device or subsystem is looking at it.
struct TopicEntity: AppEntity {
    let id: String
    let baseUrl: String
    let topic: String
    let displayName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Topic"
    static var defaultQuery = TopicEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    init(subscription: Subscription) {
        let baseUrl = subscription.baseUrl ?? ""
        let topic = subscription.topic ?? ""
        self.id = "\(baseUrl)|\(topic)"
        self.baseUrl = baseUrl
        self.topic = topic
        self.displayName = subscription.displayName()
    }
}
