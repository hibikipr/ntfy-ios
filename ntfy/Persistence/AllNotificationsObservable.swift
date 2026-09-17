import Combine
import CoreData
import SwiftUI

class AllNotificationsObservable: NSObject, ObservableObject {
    private let tag = "AllNotificationsObservable"
    private var cancellables: Set<AnyCancellable> = []
    private var hasStructuralChange = false

    private lazy var fetchedResultsController: NSFetchedResultsController<Notification> = {
        let fetchRequest: NSFetchRequest<Notification> = Notification.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false)]
        fetchRequest.fetchBatchSize = 50

        let controller = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: Store.shared.context, sectionNameKeyPath: nil, cacheName: nil)
        controller.delegate = self
        return controller
    }()

    @Published var notifications: [Notification] = []

    override init() {
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
            Log.d(tag, "Fetching all notifications")
            try self.fetchedResultsController.performFetch()
            self.notifications = self.fetchedResultsController.fetchedObjects ?? []
        } catch {
            Log.w(tag, "Failed to fetch all notifications \(error)")
        }
    }
}

extension AllNotificationsObservable: NSFetchedResultsControllerDelegate {
    func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        hasStructuralChange = false
    }

    // Same distinction NotificationsObservable makes: an insert/delete/move is worth animating,
    // a plain attribute update like `markRead` flipping `isRead` is not. This list is the one
    // scrolled most (it aggregates every topic), and animating a full re-diff for each read-flag
    // flip made rows visibly shuffle under the finger while scrolling — and, because dismissing
    // the list fires `onDisappear` for every visible row at once, again on the way out.
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
        Log.d(tag, "Content changed, count=\(fetched.count), unread=\(unread)")
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
