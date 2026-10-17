import Foundation
import Intents
import UserNotifications

extension UNMutableNotificationContent {
    /// Reused across notification banner image downloads within a process's lifetime instead of
    /// constructing a fresh `URLSession` per notification.
    private static let notificationImageSession = URLSession(configuration: .ephemeral)

    func modify(message: Message, baseUrl: String) {
        // Body and title
        if let body = message.message {
            // The notification banner can't render rich text, so for Markdown messages we strip
            // the formatting markers to clean plain text rather than showing raw `**`/`_`/`#`.
            self.body = message.isMarkdown ? markdownToPlainText(body) : body
        }
        
        // Set notification title to short URL if there is no title. The title is always set
        // by the server, but it may be empty.
        if let title = message.title, title != "" {
            self.title = title
        } else {
            self.title = topicShortUrl(baseUrl: baseUrl, topic: message.topic)
        }
        
        // Emojify title or message
        let emojiTags = parseEmojiTags(message.tags)
        if !emojiTags.isEmpty {
            if let title = message.title, title != "" {
                self.title = emojiTags.joined(separator: "") + " " + self.title
            } else {
                self.body = emojiTags.joined(separator: "") + " " + self.body
            }
        }
        
        // Add custom actions
        //
        // We re-define the categories every time here, which is weird, but it works. When tapped, the action sets the
        // actionIdentifier in the application(didReceive) callback. This logic is handled in the AppDelegate. This approach
        // is described in a comment in https://stackoverflow.com/questions/30103867/changing-action-titles-in-interactive-notifications-at-run-time#comment122812568_30107065
        //
        // We also must set the .foreground flag, which brings the notification to the foreground and avoids an error about
        // permissions. This is described in https://stackoverflow.com/a/44580916/1440785
        configureNotificationActions(message: message)
        
        // Group by topic, and only elevate priority 5 alerts to critical when the user opted in
        // and iOS has granted critical alert permission.
        self.threadIdentifier = topicUrl(baseUrl: baseUrl, topic: message.topic)
        
        // Map priorities to interruption level (light up screen, ...) and relevance (order)
        switch message.priority {
        case 1:
            self.sound = .default
            self.interruptionLevel = .passive
            self.relevanceScore = 0
        case 2:
            self.sound = .default
            self.interruptionLevel = .passive
            self.relevanceScore = 0.25
        case 4:
            self.sound = .default
            self.interruptionLevel = .timeSensitive
            self.relevanceScore = 0.75
        case 5:
            if Store.shared.getCriticalAlertsEnabled() && Store.getCriticalAlertsAuthorized() {
                self.sound = .defaultCritical
                self.interruptionLevel = .critical
            } else {
                self.sound = .default
                self.interruptionLevel = .timeSensitive
            }
            self.relevanceScore = 1
        default:
            self.sound = .default
            self.interruptionLevel = .active
            self.relevanceScore = 0.5
        }
        
        // Make sure the userInfo matches, so that when the notification is tapped, the AppDelegate
        // can properly navigate to the right topic and re-assemble the message.
        self.userInfo = message.toUserInfo()
        self.userInfo["base_url"] = baseUrl
    }

    func attachImageIfNeeded(message: Message, user: BasicUser?, completionHandler: @escaping () -> Void) {
        guard let attachment = message.attachment else {
            completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
            return
        }
        guard attachment.isImageAttachment(), let url = URL(string: attachment.url) else {
            completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
            return
        }

        if let localFileUrl = AttachmentFileStore.existingLocalFileUrl(
            notificationID: message.id,
            remoteUrl: url,
            attachment: attachment,
            mimeType: attachment.type
        ) {
            DispatchQueue.main.async {
                let didAttachImage = self.attachLocalImage(from: localFileUrl)
                self.completeAttachmentHandling(message: message, didAttachImage: didAttachImage, completionHandler: completionHandler)
            }
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        if let user = user {
            request.setValue(user.toHeader(), forHTTPHeaderField: "Authorization")
        }

        Self.notificationImageSession.downloadTask(with: request) { tempUrl, response, _ in
            guard
                let tempUrl,
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                self.completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
                return
            }

            let mimeType = attachment.type ?? httpResponse.mimeType
            guard mimeType?.lowercased().hasPrefix("image/") == true || attachment.isImageAttachment() else {
                self.completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
                return
            }

            do {
                let downloaded = try AttachmentFileStore.storeDownloadedTemporaryFile(
                    notificationID: message.id,
                    remoteUrl: url,
                    attachment: attachment,
                    temporaryFileUrl: tempUrl,
                    mimeType: mimeType
                )
                Store.shared.completeAttachmentDownload(
                    notificationID: message.id,
                    localPath: downloaded.localFileUrl.path,
                    resolvedType: downloaded.mimeType,
                    resolvedSize: downloaded.size
                )
                DispatchQueue.main.async {
                    let didAttachImage = self.attachLocalImage(from: downloaded.localFileUrl)
                    self.completeAttachmentHandling(message: message, didAttachImage: didAttachImage, completionHandler: completionHandler)
                }
            } catch {
                Log.w("NotificationContent", "Failed to create notification attachment", error)
                self.completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
            }
        }.resume()
    }

    /// Shows the message icon (see `Message.icon`), if any, as the sender image of a
    /// communication notification. If iOS refuses that, the icon is attached as an image instead,
    /// unless the notification already shows an image attachment. Downloading the icon follows
    /// the attachment auto-download setting and gives up quickly, so this always completes with
    /// the notification content to deliver, the original one if the icon can't be shown.
    func withIconIfNeeded(message: Message, completionHandler: @escaping (UNNotificationContent) -> Void) {
        guard
            let iconUrl = message.iconUrl,
            let maxSize = NotificationIconStore.maxDownloadSize(
                autoDownloadMaxSize: Store.shared.getAttachmentAutoDownloadMaxSize()
            )
        else {
            completionHandler(self)
            return
        }
        Task {
            let iconFileUrl: URL
            do {
                iconFileUrl = try await NotificationIconStore.icon(for: iconUrl, maxSize: maxSize)
            } catch {
                Log.w("NotificationContent", "Failed to download icon \(iconUrl)", error)
                completionHandler(self)
                return
            }
            completionHandler(self.withIcon(fileUrl: iconFileUrl))
        }
    }

    private func withIcon(fileUrl: URL) -> UNNotificationContent {
        guard let data = try? Data(contentsOf: fileUrl) else {
            return self
        }
        let image = INImage(imageData: data)
        let sender = INPerson(
            personHandle: INPersonHandle(value: threadIdentifier, type: .unknown),
            nameComponents: nil,
            displayName: title,
            image: image,
            contactIdentifier: nil,
            customIdentifier: threadIdentifier
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: nil,
            conversationIdentifier: threadIdentifier,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        intent.setImage(image, forParameterNamed: \.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { error in
            if let error {
                Log.w("NotificationContent", "Failed to donate message interaction", error)
            }
        }
        do {
            return try updating(from: intent)
        } catch {
            Log.w("NotificationContent", "Cannot show icon as communication notification, attaching it instead", error)
        }
        if attachments.isEmpty, let attachment = iconAttachment(fileUrl: fileUrl) {
            attachments = [attachment]
        }
        return self
    }

    /// Attaching a file moves it into the notification store, so this attaches a copy to keep
    /// the cached icon.
    private func iconAttachment(fileUrl: URL) -> UNNotificationAttachment? {
        guard let data = try? Data(contentsOf: fileUrl) else {
            return nil
        }
        let fileExtension = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
        let copyUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: copyUrl)
            return try UNNotificationAttachment(identifier: "icon", url: copyUrl)
        } catch {
            Log.w("NotificationContent", "Failed to attach icon", error)
            return nil
        }
    }

    private func attachLocalImage(from localFileUrl: URL) -> Bool {
        do {
            let notificationAttachment = try UNNotificationAttachment(identifier: "attachment", url: localFileUrl)
            attachments = attachments + [notificationAttachment]
            return true
        } catch {
            Log.w("NotificationContent", "Failed to attach local image", error)
            return false
        }
    }

    private func configureNotificationActions(message: Message) {
        let userActions = message.actions ?? []
        let actions = userActions.prefix(4).map {
            UNNotificationAction(identifier: $0.id, title: $0.label, options: [.foreground])
        }

        guard !actions.isEmpty else {
            categoryIdentifier = ""
            return
        }

        let categoryIdentifier = "ntfyActions"
        self.categoryIdentifier = categoryIdentifier

        let center = UNUserNotificationCenter.current()
        let category = UNNotificationCategory(identifier: categoryIdentifier, actions: actions, intentIdentifiers: [])
        center.getNotificationCategories { existingCategories in
            let preservedCategories = existingCategories.filter { $0.identifier != categoryIdentifier }
            center.setNotificationCategories(Set(preservedCategories).union([category]))
        }
    }

    private func completeAttachmentHandling(message: Message, didAttachImage: Bool, completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.appendAttachmentSummaryIfNeeded(message: message, didAttachImage: didAttachImage)
            completionHandler()
        }
    }

    private func appendAttachmentSummaryIfNeeded(message: Message, didAttachImage: Bool) {
        guard let attachment = message.attachment else {
            return
        }
        if attachment.isImageAttachment(), didAttachImage {
            return
        }

        let summary = fallbackAttachmentSummary(attachment: attachment)
        guard !summary.isEmpty else {
            return
        }

        if body.isEmpty {
            body = summary
        } else {
            body = body + "\n\n" + summary
        }
    }
}

private func fallbackAttachmentSummary(attachment: MessageAttachment) -> String {
    var parts = [attachment.displayName()]
    if let size = attachment.size, size > 0 {
        parts.append(formatBytes(size))
    }
    if attachment.isExpired() {
        parts.append("expired")
    }
    return "Attachment: " + parts.joined(separator: ", ")
}

extension UNUserNotificationCenter {
    /// Removes the delivered notifications of the given sequences in a topic, e.g. because they
    /// were deleted, cleared or replaced by a newer version (see `Message.sequenceId`). Matches on
    /// the message in the userInfo, so this covers both pushes and local notifications.
    func removeDeliveredNotifications(
        baseUrl: String,
        topic: String,
        sequenceIds: Set<String>,
        except exceptIdentifier: String? = nil,
        completionHandler: @escaping () -> Void
    ) {
        guard !sequenceIds.isEmpty else {
            completionHandler()
            return
        }
        getDeliveredNotifications { notifications in
            let identifiers = notifications
                .filter { notification in
                    notification.request.identifier != exceptIdentifier
                        && Self.isDeliveredNotification(
                            userInfo: notification.request.content.userInfo,
                            of: sequenceIds,
                            baseUrl: baseUrl,
                            topic: topic
                        )
                }
                .map(\.request.identifier)
            if !identifiers.isEmpty {
                self.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
            completionHandler()
        }
    }

    static func isDeliveredNotification(userInfo: [AnyHashable: Any], of sequenceIds: Set<String>, baseUrl: String, topic: String) -> Bool {
        guard let message = Message.from(userInfo: userInfo), message.topic == topic else {
            return false
        }
        let notificationBaseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
        return normalizeBaseUrl(notificationBaseUrl) == normalizeBaseUrl(baseUrl)
            && sequenceIds.contains(message.effectiveSequenceId)
    }
}
