import AppIntents

struct TopicEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [TopicEntity] {
        await MainActor.run {
            (Store.shared.getSubscriptions() ?? [])
                .map(TopicEntity.init)
                .filter { identifiers.contains($0.id) }
        }
    }

    func suggestedEntities() async throws -> [TopicEntity] {
        await MainActor.run {
            (Store.shared.getSubscriptions() ?? []).map(TopicEntity.init)
        }
    }
}
