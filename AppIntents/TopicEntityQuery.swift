import AppIntents

struct TopicEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [TopicEntity] {
        let subscriptions = await MainActor.run { Store.shared.getSubscriptions() ?? [] }
        return subscriptions
            .map(TopicEntity.init)
            .filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TopicEntity] {
        let subscriptions = await MainActor.run { Store.shared.getSubscriptions() ?? [] }
        return subscriptions.map(TopicEntity.init)
    }
}
