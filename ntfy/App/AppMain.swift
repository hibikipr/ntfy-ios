import SwiftUI
import Firebase

// TODO: Errors are not shown to the user, but instead just logged

@main
struct AppMain: App {
    private let tag = "AppMain"
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate: AppDelegate
    @StateObject private var store = Store.shared
    @StateObject private var iconManager = AppIconManager()

    init() {
        Log.d(tag, "Launching ntfy 🥳. Welcome!")
        Log.d(tag, "Base URL is \(Config.appBaseUrl), user agent is \(ApiService.userAgent)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(iconManager)
                .environment(delegate)
                .environment(\.managedObjectContext, store.context)
                .tint(iconManager.current.accentColor)
                // `.onAppear` covers cold launch reliably: `.onReceive` only delivers
                // notifications posted *after* the Combine subscription is attached, and on a
                // cold launch `didBecomeActiveNotification` can be posted before SwiftUI finishes
                // mounting this view's modifiers, silently dropping the very first refresh. Also
                // closes the window where a push notification's NSE-written Core Data row hasn't
                // landed yet by the time Store.init() computed its initial unreadCount.
                .onAppear(perform: refreshAfterBecomingActive)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Use this hook instead of applicationDidBecomeActive, see https://stackoverflow.com/a/68888509/1440785
                    // That post also explains how to start SwiftUI from AppDelegate if that's ever needed.
                    refreshAfterBecomingActive()
                }
        }
    }

    private func refreshAfterBecomingActive() {
        Log.d(tag, "App became active, refreshing objects")
        store.hardRefresh()
        delegate.refreshNotificationSettings()
        delegate.subscribeToFirebaseTopics()
    }
}
