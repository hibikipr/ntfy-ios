import Foundation
import FirebaseCore
import FirebaseMessaging

/// Manager to combine persisting a subscription to the data store and subscribing to Firebase.
/// This is to centralize the logic in one place.
struct SubscriptionManager {
    private let tag = "SubscriptionManager"
    var store: Store
    
    /// - Parameter syncToCloud: `false` when this call is `TopicSyncCoordinator` *applying* a
    ///   change that came from another device. That skips notifying the coordinator entirely,
    ///   which is what keeps the change from echoing straight back out to iCloud. It replaces an
    ///   earlier ambient "is a remote change being applied" flag, which couldn't work reliably
    ///   because this method's coordinator call doesn't necessarily run inline with the caller.
    func subscribe(baseUrl: String, topic: String, syncToCloud: Bool = true) {
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        let firebaseTopicName = firebaseTopic(baseUrl: normalizedBaseUrl, topic: topic)
        if FirebaseApp.app() != nil {
            Log.d(tag, "Subscribing to \(topicUrl(baseUrl: normalizedBaseUrl, topic: topic))")
            Messaging.messaging().subscribe(toTopic: firebaseTopicName) { error in
                if let error {
                    Log.e(tag, "Firebase subscribe failed for \(firebaseTopicName)", error)
                } else {
                    Log.d(tag, "Firebase subscribe succeeded for \(firebaseTopicName)")
                }
            }
        }
        let subscription = store.saveSubscription(baseUrl: normalizedBaseUrl, topic: topic)
        if syncToCloud {
            // Real subscribes come off a background queue (SubscriptionAddView dispatches to
            // .global), so `MainActor.assumeIsolated` here would trap deterministically. A real
            // async hop is safe now that reconciliation opts out via `syncToCloud: false` rather
            // than relying on the coordinator observing an in-flight flag.
            Task { @MainActor in
                TopicSyncCoordinator.shared.localSubscriptionDidChange(subscription)
            }
        }
        Task {
            await poll(subscription, notifyOnNewMessages: false)
        }
    }

    /// - Parameter syncToCloud: see `subscribe(baseUrl:topic:syncToCloud:)`. Passing `false` (which
    ///   `TopicSyncCoordinator` does when applying a remote unsubscribe) skips the coordinator call
    ///   outright, so there is nothing left to race with a concurrent re-subscribe import.
    func unsubscribe(_ subscription: Subscription, syncToCloud: Bool = true) {
        Log.d(tag, "Unsubscribing from \(subscription.urlString())")
        let baseUrl = subscription.baseUrl
        let topic = subscription.topic
        if syncToCloud, let baseUrl, let topic {
            Task { @MainActor in
                TopicSyncCoordinator.shared.localSubscriptionWasRemoved(baseUrl: baseUrl, topic: topic)
            }
        }
        DispatchQueue.main.async {
            if let baseUrl, let topic, FirebaseApp.app() != nil {
                let firebaseTopicName = firebaseTopic(baseUrl: baseUrl, topic: topic)
                Messaging.messaging().unsubscribe(fromTopic: firebaseTopicName) { error in
                    if let error {
                        Log.e(tag, "Firebase unsubscribe failed for \(firebaseTopicName)", error)
                    } else {
                        Log.d(tag, "Firebase unsubscribe succeeded for \(firebaseTopicName)")
                    }
                }
            }
            store.delete(subscription: subscription)
        }
    }
    
    /// Polls the subscription for new messages. Overlapping polls of the same subscription share
    /// one request, and one that polled successfully moments ago is skipped (see `PollCoalescer`),
    /// unless `force` is set: for when the user asked to refresh that one topic.
    @discardableResult
    @MainActor
    func poll(_ subscription: Subscription, notifyOnNewMessages: Bool = true, force: Bool = false) async -> [Message] {
        // This is a bit of a hack but it prevents us from polling dead subscriptions
        guard subscription.baseUrl != nil else {
            Log.d(tag, "Attempting to poll dead subscription failed")
            return []
        }
        let statusKey = subscription.urlString()
        return await PollCoalescer.shared.poll(key: statusKey, force: force) {
            await performPoll(subscription, statusKey: statusKey, notifyOnNewMessages: notifyOnNewMessages)
        }
    }

    /// One poll request. `succeeded` is false when it was skipped or failed.
    @MainActor
    private func performPoll(_ subscription: Subscription, statusKey: String, notifyOnNewMessages: Bool) async -> PollCoalescer.Outcome {
        let pollStatus = PollStatusCenter.shared
        if let until = pollStatus.rateLimitedUntil(statusKey) {
            Log.d(tag, "Skipping poll of \(statusKey), rate limited until \(until)")
            return .init(messages: [], succeeded: false)
        }
        let user = store.getCredentials(baseUrl: subscription.baseUrl!)
        Log.d(tag, "Polling from \(subscription.urlString()) with user \(user != nil ? "<redacted>" : "anonymous")")
        let messages: [Message]
        do {
            let response = try await ApiService.shared.poll(subscription: subscription, user: user)
            messages = response.messages
            if response.truncated {
                Log.w(tag, "Server truncated the replay for \(statusKey), older messages were not returned")
            }
            pollStatus.record(response.truncated ? .truncated : nil, for: statusKey)
        } catch let error as PollError {
            Log.e(tag, "Polling failed", error)
            pollStatus.record(PollIssue(error), for: statusKey)
            return .init(messages: [], succeeded: false)
        } catch {
            // Network errors (offline, timeouts) are transient and not worth a banner
            Log.e(tag, "Polling failed", error)
            return .init(messages: [], succeeded: false)
        }
        Log.d(tag, "Polling success, \(messages.count) new message(s)", messages)
        guard !messages.isEmpty else {
            return .init(messages: [], succeeded: true)
        }
        let saved = store.save(notificationsFromMessages: messages, withSubscription: subscription)
        guard
            notifyOnNewMessages,
            !saved.outdatedSequenceIds.isEmpty,
            let baseUrl = subscription.baseUrl,
            let topic = subscription.topic
        else {
            return .init(messages: saved.shown, succeeded: true)
        }
        await withCheckedContinuation { continuation in
            LocalNotificationPoster.update(baseUrl: baseUrl, topic: topic, saved: saved) {
                continuation.resume()
            }
        }
        return .init(messages: saved.shown, succeeded: true)
    }
}

/// Why the last poll of a subscription didn't fully work, shown in its notification list
enum PollIssue: Equatable {
    case unauthorized
    case rateLimited(until: Date, message: String?)
    case serverError(status: Int, message: String?)
    case truncated

    /// Polls are skipped for this long after a 429; ntfy doesn't send `Retry-After`
    static let rateLimitBackoff: TimeInterval = 5 * 60

    init(_ error: PollError, now: Date = Date()) {
        switch error {
        case .unauthorized:
            self = .unauthorized
        case .rateLimited(let message):
            self = .rateLimited(until: now.addingTimeInterval(PollIssue.rateLimitBackoff), message: message)
        case .server(let status, let message):
            self = .serverError(status: status, message: message)
        }
    }

    var title: String {
        switch self {
        case .unauthorized: return String(localized: "Not authorized")
        case .rateLimited: return String(localized: "Server limit reached")
        case .serverError: return String(localized: "Server error")
        case .truncated: return String(localized: "Older messages not loaded")
        }
    }

    var detail: String {
        switch self {
        case .unauthorized:
            return String(localized: "The server refused access to this topic. Check the user for this server in Settings.")
        case .rateLimited(let until, let message):
            let time = until.formatted(date: .omitted, time: .shortened)
            let pause = String(localized: "Refreshing pauses until \(time).")
            return message.map { "\(PollIssue.sentence($0)). \(pause)" } ?? pause
        case .serverError(let status, let message):
            return message.map { "\(PollIssue.sentence($0)) (HTTP \(status))." } ?? String(localized: "The server responded with HTTP \(status).")
        case .truncated:
            return String(localized: "The server only returned its newest messages for this topic.")
        }
    }

    /// Server error messages come in English and lowercase, e.g. "limit reached: too many requests"
    private static func sentence(_ message: String) -> String {
        return message.prefix(1).uppercased() + message.dropFirst()
    }

    var systemImage: String {
        switch self {
        case .unauthorized: return "lock.trianglebadge.exclamationmark"
        case .rateLimited: return "hourglass"
        case .serverError: return "exclamationmark.triangle"
        case .truncated: return "info.circle"
        }
    }
}

/// Keeps polls of the same subscription from piling up. Several screens and the background
/// "~poll" handler each poll every subscription, one request apiece, and they overlap: a few in a
/// row used up ntfy's per-client request limit (a burst of 60, then 1 per 5 s). A poll already in
/// flight is joined instead of repeated, and one that succeeded within `minInterval` is skipped.
@MainActor
final class PollCoalescer {
    static let shared = PollCoalescer()

    struct Outcome {
        var messages: [Message]
        /// Whether the server answered. Only a successful poll starts the `minInterval` window,
        /// so a failed or skipped one can be retried right away.
        var succeeded: Bool
    }

    let minInterval: TimeInterval
    private let now: () -> Date
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    private var lastSuccess: [String: Date] = [:]

    init(minInterval: TimeInterval = 10, now: @escaping () -> Date = Date.init) {
        self.minInterval = minInterval
        self.now = now
    }

    /// Runs `request` for `key`, or joins the one in flight, or skips it if `key` polled
    /// successfully within `minInterval` (unless `force`). Returns the messages it brought.
    func poll(key: String, force: Bool = false, _ request: @escaping @MainActor () async -> Outcome) async -> [Message] {
        if let running = inFlight[key] {
            return await running.value.messages
        }
        if !force, let last = lastSuccess[key], now().timeIntervalSince(last) < minInterval {
            Log.d("PollCoalescer", "Skipping poll of \(key), polled \(Int(now().timeIntervalSince(last)))s ago")
            return []
        }
        let task = Task { @MainActor in await request() }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        if outcome.succeeded {
            lastSuccess[key] = now()
        }
        return outcome.messages
    }
}

/// Last poll outcome per subscription (keyed by `Subscription.urlString()`), kept in memory only.
@MainActor
final class PollStatusCenter: ObservableObject {
    static let shared = PollStatusCenter()

    init() {}

    @Published private(set) var issues: [String: PollIssue] = [:]

    func record(_ issue: PollIssue?, for key: String) {
        guard issues[key] != issue else { return }
        issues[key] = issue
        // A rate limit is over when its back-off ends, not when the next poll succeeds: clear it
        // then, so the list doesn't keep saying refreshing is paused until a time that has passed.
        if case .rateLimited(let until, _) = issue {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
                if self?.issues[key] == issue {
                    self?.issues[key] = nil
                }
            }
        }
    }

    /// The end of an active rate limit back-off, or nil if polling is allowed
    func rateLimitedUntil(_ key: String, now: Date = Date()) -> Date? {
        guard case .rateLimited(let until, _) = issues[key], until > now else { return nil }
        return until
    }
}
