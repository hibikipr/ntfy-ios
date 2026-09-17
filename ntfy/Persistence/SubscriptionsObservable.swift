import CoreData
import SwiftUI

class SubscriptionsObservable: NSObject, ObservableObject {
    private let tag = "SubscriptionsObservable"
    private var hasStructuralChange = false

    override init() {
        super.init()

        // This will force the initialization of fetchedResultsController
        _ = self.fetchedResultsController
    }

    private lazy var fetchedResultsController: NSFetchedResultsController<Subscription> = {
        let fetchRequest: NSFetchRequest<Subscription> = Subscription.fetchRequest()
        // Secondary sort on `topic` makes display order deterministic when two subscriptions
        // have an equal `sortRank` (reachable in practice: two devices independently computing
        // the same `maxRank + 1` before syncing, or a backfill save silently failing and leaving
        // every rank at the migration default) — otherwise NSFetchedResultsController's order for
        // ties is undefined and rows can visibly reshuffle between fetches.
        fetchRequest.sortDescriptors = [
            NSSortDescriptor(key: "sortRank", ascending: true),
            NSSortDescriptor(key: "topic", ascending: true)
        ]

        let controller = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: Store.shared.context, sectionNameKeyPath: nil, cacheName: nil)
        controller.delegate = self

        do {
            Log.d(tag, "Fetching subscriptions")
            try controller.performFetch()
        } catch {
            Log.w(tag, "Failed to fetch subscriptions: \(error)", error)
        }

        return controller
    }()

    var subscriptions: [Subscription] {
        fetchedResultsController.fetchedObjects ?? []
    }
}

extension SubscriptionsObservable: NSFetchedResultsControllerDelegate {
    func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        hasStructuralChange = false
    }

    // Only a subscribe/unsubscribe/reorder (insert/delete/move) should animate the topic list.
    // Attribute-only updates land here constantly — `poll()` rewrites `lastNotificationId` for
    // every topic on appear and on pull-to-refresh, and topic sync rewrites metadata — and
    // animating a full list re-diff for those made rows slide around while the list was being
    // scrolled or dismissed.
    func controller(
        _ controller: NSFetchedResultsController<NSFetchRequestResult>,
        didChange anObject: Any,
        at indexPath: IndexPath?,
        for type: NSFetchedResultsChangeType,
        newIndexPath: IndexPath?
    ) {
        switch type {
        case .insert, .delete, .move:
            hasStructuralChange = true
        case .update:
            break
        @unknown default:
            hasStructuralChange = true
        }
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        Log.d(tag, "Subscriptions changed")
        let shouldAnimate = hasStructuralChange
        DispatchQueue.main.async {
            if shouldAnimate {
                withAnimation {
                    self.objectWillChange.send()
                }
            } else {
                self.objectWillChange.send()
            }
        }
    }
}
