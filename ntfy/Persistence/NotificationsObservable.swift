import Combine
import CoreData
import SwiftUI

class NotificationsObservable: NSObject, ObservableObject {
    private let tag = "NotificationsObservable"
    private var subscriptionID: NSManagedObjectID
    private var cancellables: Set<AnyCancellable> = []

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
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        let fetched = self.fetchedResultsController.fetchedObjects ?? []
        let unread = fetched.filter { !$0.isRead }.count
        Log.d(tag, "Content changed for subscription \(subscriptionID), count=\(fetched.count), unread=\(unread)")
        DispatchQueue.main.async {
            withAnimation {
                self.notifications = fetched
            }
        }
    }
}
