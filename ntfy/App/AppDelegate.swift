import UIKit
import SafariServices
import UserNotifications
import Firebase
import FirebaseCore
import FirebaseMessaging
import CoreData

class AppDelegate: UIResponder, UIApplicationDelegate, ObservableObject {
    private let tag = "AppDelegate"
    private let pollTopic = "~poll" // See ntfy server if ever changed
    
    // Implements navigation from notifications, see https://stackoverflow.com/a/70731861/1440785
    @Published var selectedBaseUrl: String? = nil
    @Published private(set) var criticalAlertSetting: UNNotificationSetting = .notSupported

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.d(tag, "Launching AppDelegate")

        FirebaseApp.configure()
        FirebaseConfiguration.shared.setLoggerLevel(.warning)

        // Register app permissions for push notifications
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        requestStandardNotificationAuthorization()
        refreshNotificationSettings()
        
        // Register too receive remote notifications
        application.registerForRemoteNotifications()
                
        return true
    }

    func refreshNotificationSettings(completion: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let isAuthorized = settings.criticalAlertSetting == .enabled
            DispatchQueue.main.async {
                self.criticalAlertSetting = settings.criticalAlertSetting
                Store.saveCriticalAlertsAuthorized(isAuthorized)
                completion?()
            }
        }
    }

    func requestCriticalAlertsAuthorization(completion: @escaping (Bool) -> Void) {
        if criticalAlertSetting == .enabled {
            completion(true)
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound, .criticalAlert]) { success, error in
            if let error {
                Log.e(self.tag, "Failed to register for critical alerts", error)
            } else if success {
                Log.d(self.tag, "Successfully requested critical alerts")
            }

            self.refreshNotificationSettings {
                completion(self.criticalAlertSetting == .enabled)
            }
        }
    }

    // TODO: Needs to be tested on multiple devices/iOS versions
    func openNotificationSettings() {
        let settingsURLString: String
        #if targetEnvironment(simulator)
        settingsURLString = UIApplication.openSettingsURLString
        #else
        if #available(iOS 16.0, *) {
            settingsURLString = UIApplication.openNotificationSettingsURLString
        } else if #available(iOS 15.4, *) {
            settingsURLString = UIApplicationOpenNotificationSettingsURLString
        } else {
            settingsURLString = UIApplication.openSettingsURLString
        }
        #endif
        guard let url = URL(string: settingsURLString) else {
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func requestStandardNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { success, error in
            guard success else {
                Log.e(self.tag, "Failed to register for local push notifications", error)
                return
            }
            Log.d(self.tag, "Successfully registered for local push notifications")
        }
    }
    
    /// Executed when a background notification arrives on the "~poll" topic. This is used to trigger polling of local topics.
    /// See https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/pushing_background_updates_to_your_app
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Log.d(tag, "Background notification received", userInfo)
        
        // Exit out early if this message is not expected
        let topic = userInfo["topic"] as? String ?? ""
        if topic != pollTopic {
            completionHandler(.noData)
            return
        }

        // Retry any previously-failed Firebase subscriptions while we're already awake (#1305)
        subscribeToFirebaseTopics()

        // Poll and show new messages as notifications
        let store = Store.shared
        let subscriptionManager = SubscriptionManager(store: store)
        let subscriptions = store.getSubscriptions() ?? []
        guard !subscriptions.isEmpty else {
            completionHandler(.noData)
            return
        }

        let group = DispatchGroup()
        let resultQueue = DispatchQueue(label: "io.heckel.ntfy.background-poll-result")
        var didReceiveNewData = false
        subscriptions.forEach { subscription in
            group.enter()
            guard subscription.baseUrl != nil else {
                Log.w(tag, "Skipping background poll notification for subscription with missing baseUrl")
                group.leave()
                return
            }
            subscriptionManager.poll(subscription) { newMessages in
                if !newMessages.isEmpty {
                    resultQueue.sync {
                        didReceiveNewData = true
                    }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completionHandler(didReceiveNewData ? .newData : .noData)
        }
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { data in String(format: "%02.2hhx", data) }.joined()
        Messaging.messaging().apnsToken = deviceToken
        Log.d(tag, "Registered for remote notifications. Passing APNs token \(token.prefix(12))... to Firebase")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.e(tag, "Failed to register for remote notifications", error)
    }
    
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Executed when the app is in the foreground. The notification-service-extension (NSE) is what
    /// normally saves an incoming message to Core Data, but NSE does not run on the Simulator (a
    /// documented Apple limitation) and can be skipped by the system in some foreground scenarios on
    /// real devices too. Save here as a fallback so the message always ends up in the topic list, not
    /// just as a transient banner. Safe to call even when NSE also saves the same message — Store's
    /// save path already dedupes by message ID before inserting.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        Log.d(tag, "Notification received via userNotificationCenter(willPresent)", userInfo)
        if let message = Message.from(userInfo: userInfo), message.event == "message" {
            let baseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
            _ = Store.shared.save(notificationFromMessage: message, baseUrl: baseUrl, topic: message.topic)
        }
        completionHandler([[.banner, .sound]])
    }
    
    /// Executed when the user clicks on the notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Log.d(tag, "Notification received via userNotificationCenter(didReceive)", userInfo)
        guard let message = Message.from(userInfo: userInfo) else {
            Log.w(tag, "Cannot convert userInfo to message", userInfo)
            completionHandler()
            return
        }
        
        let baseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
        let action = message.actions?.first { $0.id == response.actionIdentifier }
        
        // Show current topic
        if message.topic != "" {
            selectedBaseUrl = topicUrl(baseUrl: baseUrl, topic: message.topic)
        }
        
        // Execute user action or click action (if any)
        if let action = action {
            ActionExecutor.execute(action)
        } else if let click = message.click, click != "", let url = URL(string: click) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    
        completionHandler()
    }
}

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let fcmToken = fcmToken, !fcmToken.isEmpty {
            Log.d(tag, "Firebase token received: \(fcmToken.prefix(12))...")
        } else {
            Log.w(tag, "Firebase token missing")
        }

        subscribeToFirebaseTopics()
    }
}

extension AppDelegate {
    /// (Re-)subscribes to the "~poll" topic and every current subscription's Firebase topic.
    /// Safe to call repeatedly: Firebase no-ops on an already-subscribed topic, so this only
    /// meaningfully retries topics that previously failed to subscribe. Called on token
    /// refresh, on every app foreground, and on every background "~poll" trigger, to recover
    /// from silent subscription failures (network blip, token rotation) without waiting for
    /// the token itself to change again.
    func subscribeToFirebaseTopics() {
        // Subscribe to ~poll topic
        Messaging.messaging().subscribe(toTopic: pollTopic) { error in
            if let error {
                Log.e(self.tag, "Firebase subscribe failed for \(self.pollTopic)", error)
            } else {
                Log.d(self.tag, "Firebase subscribe succeeded for \(self.pollTopic)")
            }
        }

        // Re-subscribe to Firebase for all topics
        let store = Store.shared
        store.getSubscriptions()?.forEach { subscription in
            if let baseUrl = subscription.baseUrl, let topic = subscription.topic {
                let firebaseTopicName = firebaseTopic(baseUrl: baseUrl, topic: topic)
                Log.d(tag, "Re-subscribing to topic \(baseUrl)/\(topic)")
                Messaging.messaging().subscribe(toTopic: firebaseTopicName) { error in
                    if let error {
                        Log.e(self.tag, "Firebase subscribe failed for \(firebaseTopicName)", error)
                    } else {
                        Log.d(self.tag, "Firebase subscribe succeeded for \(firebaseTopicName)")
                    }
                }
            }
        }
    }
}
