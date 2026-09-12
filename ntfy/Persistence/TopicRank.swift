import Foundation

/// Pure helper for computing a moved topic's new `Subscription.sortRank` from a drag-to-reorder,
/// without rewriting every other row's rank. Keeping a reorder to a single changed field is what
/// lets it use the same last-write-wins sync semantics as `customDisplayName`/`icon` — see
/// docs/superpowers/specs/2026-09-11-ios27-adoption-design.md.
enum TopicRank {
    /// - Parameters:
    ///   - destinationIndex: the index within `orderedRanks` the moved topic should land before
    ///     (`orderedRanks.count` or beyond means "move to the end").
    ///   - orderedRanks: the current ranks of every *other* topic, in their current display
    ///     order (i.e. with the moved topic already removed).
    static func rank(insertingBefore destinationIndex: Int, in orderedRanks: [Double]) -> Double {
        if orderedRanks.isEmpty {
            return 0
        }
        if destinationIndex <= 0 {
            return orderedRanks[0] - 1
        }
        if destinationIndex >= orderedRanks.count {
            return orderedRanks[orderedRanks.count - 1] + 1
        }
        return (orderedRanks[destinationIndex - 1] + orderedRanks[destinationIndex]) / 2
    }
}
