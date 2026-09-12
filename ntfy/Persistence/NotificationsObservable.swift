import Combine
import CoreData
import SwiftUI

class NotificationsObservable: NSObject, ObservableObject {
    private let tag = "NotificationsObservable"
    private var subscriptionID: NSManagedObjectID
    private var cancellables: Set<AnyCancellable> = []
    private var hasStructuralChange = false

    private lazy var fetchedResultsController: NSFetchedResultsController<Notification> = {
        let fetchRequest: NSFetchRequest<Notification> = Notification.fetchRequest()

        // Filter by the desired subscription
        fetchRequest.predicate = NSPredicate(format: "subscription == %@", subscriptionID)

        // Sort descriptors if you need them
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false)] // Assuming you have a 'date' attribute on the NotificationEntity

        let controller = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: Store.shared.context, sectionNameKeyPath: nil, cacheName: nil)
        controller.delegate = self
        return controller
    }()

    @Published var notifications: [Notification] = []

    init(subscriptionID: NSManagedObjectID) {
        self.subscriptionID = subscriptionID
        super.init()

        performFetch()

        // `controllerDidChangeContent` alone won't fire for rows inserted by the NSE (a separate
        // process/context) — re-fetch explicitly whenever Store signals a hard refresh.
        NotificationCenter.default
            .publisher(for: Store.didHardRefreshNotification)
            .sink { [weak self] _ in
                self?.performFetch()
            }
            .store(in: &cancellables)
    }

    private func performFetch() {
        do {
            Log.d(tag, "Fetching notifications")
            try self.fetchedResultsController.performFetch()
            self.notifications = self.fetchedResultsController.fetchedObjects ?? []
        } catch {
            Log.w(tag, "Failed to fetch notifications \(error)")
        }
    }
}

extension NotificationsObservable: NSFetchedResultsControllerDelegate {
    func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        hasStructuralChange = false
    }

    // Distinguishes a genuine insert/delete/move (worth animating) from a plain attribute update
    // like `markRead` flipping `isRead` — animating a full list re-diff on every read-marking is
    // what was causing the scroll-time jank.
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
        let fetched = self.fetchedResultsController.fetchedObjects ?? []
        let unread = fetched.filter { !$0.isRead }.count
        Log.d(tag, "Content changed for subscription \(subscriptionID), count=\(fetched.count), unread=\(unread)")
        let shouldAnimate = hasStructuralChange
        DispatchQueue.main.async {
            if shouldAnimate {
                withAnimation {
                    self.notifications = fetched
                }
            } else {
                self.notifications = fetched
            }
        }
    }
}
